import ImageIO
import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

private struct PendingPageCopy {
    let destinationID: UUID
    let pageIndices: Set<Int>
    let sourceRevisionID: UUID
    let destinationRevisionID: UUID
}

private struct PendingPageRange {
    let indices: Set<Int>
    let sourceRevisionID: UUID
}

struct PageOrganizerView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let startInSelectionMode: Bool
    let initialSelectedPageIndices: Set<Int>
    let onCreated: (DocumentRoute) -> Void
    let onPrepare: () -> Void

    @State private var pendingDeleteIndex: Int?
    @State private var pendingDeletionRevisionID: UUID?
    @State private var pendingBulkDeleteIndices: Set<Int> = []
    @State private var selectedIndices: Set<Int> = []
    @State private var isSelecting: Bool
    @State private var isImportingPages = false
    @State private var isChoosingDestination = false
    @State private var isPresentingPageSelection = false
    @State private var isPresentingPageActions = false
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
    @State private var pendingPageRange: PendingPageRange?
    @State private var pendingPageCopy: PendingPageCopy?
    @State private var mutationTask: Task<Void, Never>?
    @State private var mutationGeneration = UUID()
    @State private var locallyCommittedRevisionID: UUID?
    @State private var pageMutationStopRequested = false
    @State private var pageMutationErrorMessage: String?
    @State private var pageMutationErrorFeedback = 0
    @State private var didRevealInitialSelection = false
    @State private var isJumpingToPage = false
    @State private var pageJumpText = ""
    @State private var pageToReveal: Int?

    init(
        recordID: UUID,
        startInSelectionMode: Bool = false,
        initialSelectedPageIndices: Set<Int> = [],
        onCreated: @escaping (DocumentRoute) -> Void,
        onPrepare: @escaping () -> Void = {}
    ) {
        self.recordID = recordID
        self.startInSelectionMode = startInSelectionMode
        self.initialSelectedPageIndices = initialSelectedPageIndices
        self.onCreated = onCreated
        self.onPrepare = onPrepare
        _selectedIndices = State(
            initialValue: initialSelectedPageIndices
        )
        _isSelecting = State(
            initialValue:
                startInSelectionMode
                    || !initialSelectedPageIndices.isEmpty
        )
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        pageJumpText = ""
                        isJumpingToPage = true
                    } label: {
                        Image(systemName: "number")
                    }
                    .disabled(isPageMutationBusy)
                    .accessibilityLabel("Go to page".localizedUI)
                    .help("Go to page".localizedUI)
                    .accessibilityIdentifier("organizerGoToPage")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            mutationTask == nil
                                ? "Close"
                                : pageMutationStopRequested
                                    ? "Stopping"
                                    : "Stop"
                        ).localizedUI
                    ) {
                        if mutationTask != nil {
                            interruptPageMutation()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(
                        pageMutationStopRequested
                            || (
                                mutationTask == nil
                                    && model.isProcessing(recordID)
                            )
                    )
                }
                if !isSelecting {
                    ToolbarItem(placement: .secondaryAction) {
                        Menu {
                            if model.canUndoPageChange(recordID: recordID) {
                                Button {
                                    startPageMutation {
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
                                    startPageMutation {
                                        await model.insertBlankPage(
                                            recordID: recordID,
                                            after: record.profile.pageCount - 1
                                        )
                                    }
                                }
                            } label: {
                                Label(
                                    "Add Blank Page",
                                    systemImage: "doc.badge.plus"
                                )
                            }

                            Button {
                                isImportingPages = true
                            } label: {
                                Label(
                                    "Add Pages from PDF",
                                    systemImage: "doc.on.doc"
                                )
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(isPageMutationBusy)
                        .accessibilityLabel("Add pages".localizedUI)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isPageMutationBusy {
                    HStack(spacing: PPSpacing.small) {
                        if let progress = model.operationProgress[recordID],
                           !pageMutationStopRequested {
                            LocalOperationProgressView(progress: progress)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                            Text(
                                (
                                    pageMutationStopRequested
                                        ? "Stopping update"
                                        : "Updating working copy"
                                ).localizedUI
                            )
                                .font(.caption.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: PPSpacing.small)
                        if mutationTask != nil {
                            Button {
                                interruptPageMutation()
                            } label: {
                                Image(systemName: "stop.fill")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .disabled(pageMutationStopRequested)
                            .accessibilityLabel("Stop".localizedUI)
                            .help("Stop".localizedUI)
                        }
                    }
                    .padding(.horizontal, PPSpacing.regular)
                    .padding(.vertical, PPSpacing.small)
                    .frame(minHeight: 44)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.62))
                            .frame(height: 0.6)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.updatesFrequently)
                } else if isSelecting {
                    extractionBar
                } else if !startInSelectionMode {
                    organizerCompletionBar
                }
            }
        }
        .alert("Go to page".localizedUI, isPresented: $isJumpingToPage) {
            TextField("Page number".localizedUI, text: $pageJumpText)
                .keyboardType(.numberPad)
                .submitLabel(.go)
                .onSubmit {
                    guard let page = validJumpPage else { return }
                    pageToReveal = page
                    isJumpingToPage = false
                }
            Button("Go".localizedUI) { pageToReveal = validJumpPage }
                .disabled(validJumpPage == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AppLocalization.format(
                "Page 1-%lld", model.record(id: recordID)?.profile.pageCount ?? 0
            ))
        }
        .onChange(of: pageJumpText) { _, value in
            let digits = value.filter(\.isNumber)
            let bounded = String(digits.prefix(6))
            if bounded != value {
                pageJumpText = bounded
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
                guard let index = pendingDeleteIndex,
                      deletionTargetsCurrentRevision()
                else { return }
                pendingDeleteIndex = nil
                startPageMutation {
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
            "Remove \(pendingBulkDeleteIndices.count) selected pages?",
            isPresented: $isConfirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Remove Pages", role: .destructive) {
                guard deletionTargetsCurrentRevision() else { return }
                let indices = pendingBulkDeleteIndices
                startConfirmedPageMutation {
                    await model.deletePages(
                        recordID: recordID,
                        indices: indices
                    )
                } onCommitted: {
                    selectedIndices.removeAll()
                    if !initialSelectedPageIndices.isEmpty {
                        isSelecting = false
                    }
                }
            }
            .accessibilityHint(
                selectedIndices.count
                    >= (model.record(id: recordID)?
                        .profile.pageCount ?? 0)
                    ? "A PDF must keep at least one page."
                        .localizedUI
                    : "Removes the selected pages from the private working copy."
                        .localizedUI
            )
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
                    model.present(error, in: paperPathSceneID)
                }
                return
            }
            startPageMutation {
                await model.appendPages(recordID: recordID, from: url)
            }
        }
        .sheet(
            isPresented: $isChoosingDestination,
            onDismiss: completePageCopySelection
        ) {
            PageCopyDestinationSheet(
                sourceRecordID: recordID,
                selectedCount: selectedIndices.count
            ) { destinationID in
                guard let sourceRevisionID =
                        model.record(id: recordID)?
                            .contentRevisionID,
                      let destinationRevisionID =
                        model.record(id: destinationID)?
                            .contentRevisionID
                else {
                    presentPageMutationError(
                        "The source or destination PDF is no longer available."
                            .localizedUI
                    )
                    isChoosingDestination = false
                    return
                }
                pendingPageCopy = PendingPageCopy(
                    destinationID: destinationID,
                    pageIndices: selectedIndices,
                    sourceRevisionID: sourceRevisionID,
                    destinationRevisionID:
                        destinationRevisionID
                )
                isChoosingDestination = false
            }
        }
        .sheet(
            isPresented: $isSelectingRange,
            onDismiss: completePageRangeSelection
        ) {
            if let record = model.record(id: recordID) {
                PageRangeSelectionSheet(
                    pageCount: record.profile.pageCount
                ) { indices in
                    pendingPageRange = PendingPageRange(
                        indices: indices,
                        sourceRevisionID: record.contentRevisionID
                    )
                    isSelectingRange = false
                }
                .presentationDetents([.medium, .large])
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
                startPageMutation {
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
                        await model.withFeedbackTarget(
                            paperPathSceneID
                        ) {
                            await model.applyPageNumbers(
                                recordID: recordID,
                                payload: payload
                            )
                        }
                    },
                    onRemoveAll: {
                        await model.withFeedbackTarget(
                            paperPathSceneID
                        ) {
                            await model.removeGeneratedPageNumbers(
                                recordID: recordID
                            )
                        }
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
                        await model.withFeedbackTarget(
                            paperPathSceneID
                        ) {
                            await model.applyWatermark(
                                recordID: recordID,
                                payload: payload
                            )
                        }
                    },
                    onRemoveAll: {
                        await model.withFeedbackTarget(
                            paperPathSceneID
                        ) {
                            await model.removeGeneratedWatermarks(
                                recordID: recordID
                            )
                        }
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
                        await model.withFeedbackTarget(
                            paperPathSceneID
                        ) {
                            await model.applyBatesNumbers(
                                recordID: recordID,
                                payload: payload
                            )
                        }
                    },
                    onRemoveAll: {
                        await model.withFeedbackTarget(
                            paperPathSceneID
                        ) {
                            await model.removeGeneratedBatesNumbers(
                                recordID: recordID
                            )
                        }
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
        .interactiveDismissDisabled(isPageMutationBusy)
        .accessibilityAction(.escape) {
            if mutationTask != nil {
                interruptPageMutation()
            } else if model.isProcessing(recordID) {
                return
            } else if isSelecting && !startInSelectionMode {
                endPageSelection()
            } else {
                dismiss()
            }
        }
        .sensoryFeedback(.selection, trigger: selectedIndices)
        .sensoryFeedback(
            .success,
            trigger: model.refreshToken(for: recordID)
        )
        .sensoryFeedback(
            .error,
            trigger: pageMutationErrorFeedback
        )
        .onChange(
            of: model.record(id: recordID)?.contentRevisionID
        ) { oldRevision, newRevision in
            guard oldRevision != newRevision else { return }
            pendingDeleteIndex = nil
            pendingDeletionRevisionID = nil
            pendingBulkDeleteIndices = []
            isConfirmingBulkDelete = false
            guard mutationTask == nil,
                  newRevision != locallyCommittedRevisionID
            else { return }
            let hadSelection = !selectedIndices.isEmpty
            selectedIndices.removeAll()
            discardPendingPageSelectionHandoffs()
            if hadSelection {
                presentPageMutationError(
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                )
            }
        }
        .onChange(
            of: model.record(id: recordID)?.profile.pageCount
        ) { _, pageCount in
            guard let pageCount else { return }
            selectedIndices = selectedIndices.filter {
                $0 >= 0 && $0 < pageCount
            }
            pageMutationErrorMessage = nil
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            discardPendingPageSelectionHandoffs()
            interruptPageMutation(invalidateResult: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            discardPendingPageSelectionHandoffs()
            interruptPageMutation(invalidateResult: true)
        }
        .onDisappear {
            discardPendingPageSelectionHandoffs()
            interruptPageMutation(invalidateResult: true)
            pageMutationErrorMessage = nil
        }
    }

    private func pageList(
        record: DocumentRecord,
        url: URL
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: PPSpacing.medium) {
                    if startInSelectionMode {
                        organizerHeader(record)
                    } else {
                        organizerCommandDeck(record)
                    }
                    if let pageMutationErrorMessage {
                        pageMutationErrorBanner(pageMutationErrorMessage)
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
                            .id(index)
                        }
                    }
                }
                .frame(maxWidth: 1_080)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
                .id(model.refreshToken(for: recordID))
            }
            .onAppear {
                revealInitialSelection(
                    using: proxy,
                    pageCount: record.profile.pageCount
                )
            }
            .onChange(of: pageToReveal) { _, page in
                guard let page, page >= 0, page < record.profile.pageCount else { return }
                withAnimation(reduceMotion ? nil : PPMotion.selection) {
                    proxy.scrollTo(page, anchor: .center)
                }
                pageToReveal = nil
            }
        }
    }

    private var validJumpPage: Int? {
        guard let page = Int(pageJumpText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let count = model.record(id: recordID)?.profile.pageCount,
              page > 0, page <= count else { return nil }
        return page - 1
    }

    private func revealInitialSelection(
        using proxy: ScrollViewProxy,
        pageCount: Int
    ) {
        guard !didRevealInitialSelection,
              let firstIndex = initialSelectedPageIndices
                .sorted()
                .first(where: { $0 >= 0 && $0 < pageCount })
        else { return }
        didRevealInitialSelection = true
        Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.22)
            ) {
                proxy.scrollTo(firstIndex, anchor: .center)
            }
        }
    }

    private func organizerHeader(_ record: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            Text(record.displayName).font(PPType.document)
            Text(AppLocalization.format("%lld pages · %lld selected", record.profile.pageCount, selectedIndices.count))
                .font(PPType.measure)
                .foregroundStyle(PPColor.textSecondary)
        }
    }

    private func organizerCommandDeck(
        _ record: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            organizerHeader(record)

            LazyVGrid(
                columns: commandColumns,
                alignment: .leading,
                spacing: 0
            ) {
                organizerCommand(
                    "Import pages",
                    detail: "Append another PDF",
                    symbol: "doc.on.doc",
                    tint: PPColor.rose
                ) {
                    isImportingPages = true
                }

                pageMarksMenu

                organizerCommand(
                    "Select by rule",
                    detail: "Choose pages faster",
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
                    startPageMutation {
                        _ = await model.undoLastPageChange(
                            recordID: recordID
                        )
                    }
                }
            }
        }
    }

    private var pageMarksMenu: some View {
        Menu {
            Button {
                isPresentingPageNumbers = true
            } label: {
                Label("Page Numbers", systemImage: "number.square")
            }
            Button {
                isPresentingWatermark = true
            } label: {
                Label("Watermark", systemImage: "textformat.alt")
            }
            Button {
                isPresentingBatesNumbers = true
            } label: {
                Label("Bates Numbering", systemImage: "number.square.fill")
            }
        } label: {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: "number.square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PPColor.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Page marks".localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PPColor.textSecondary)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPageMutationBusy)
    }

    private var pageColumns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: dynamicTypeSize.ppPrefersExpandedLayout
                        ? 260
                        : 168,
                    maximum: dynamicTypeSize.ppPrefersExpandedLayout
                        ? 360
                        : 244
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
                    minimum: dynamicTypeSize.ppPrefersExpandedLayout
                        ? 240
                        : 132,
                    maximum: dynamicTypeSize.ppPrefersExpandedLayout
                        ? 340
                        : 220
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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        disabled
                            ? PPColor.textSecondary
                            : PPColor.accent
                    )
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                        )
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || isPageMutationBusy)
        .accessibilityHint(
            disabled
                ? detail.localizedUI
                : isPageMutationBusy
                    ? "Wait for the current page update to finish."
                        .localizedUI
                    : detail.localizedUI
        )
    }

    private func pageMutationErrorBanner(
        _ message: String
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(PPColor.rose)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(PPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PPSpacing.small)
            Button {
                pageMutationErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss page update error".localizedUI)
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, PPSpacing.small)
        .background(PPColor.rose.opacity(0.08))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PPColor.rose)
                .frame(width: 2)
        }
        .accessibilityElement(children: .contain)
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
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 20))
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("organizerPage-\(index)")
            .accessibilityLabel(
                isSelecting
                    ? (
                        selected
                            ? AppLocalization.format(
                                "Deselect page %lld",
                                index + 1
                            )
                            : AppLocalization.format(
                                "Select page %lld",
                                index + 1
                            )
                    )
                    : AppLocalization.format(
                        "Select page %lld",
                        index + 1
                    )
            )

            if !isSelecting {
                HStack(spacing: 0) {
                    tileAction(
                        "Rotate clockwise",
                        symbol: "rotate.right",
                        tint: PPColor.accent
                    ) {
                        startPageMutation {
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
                startPageMutation {
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
                startPageMutation {
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
                startPageMutation {
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
                startPageMutation {
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
        .disabled(isPageMutationBusy)
        .draggable(pageDragIdentifier(index))
        .dropDestination(for: String.self) { items, _ in
            guard !isSelecting,
                  !isPageMutationBusy,
                  let item = items.first,
                  let sourceIndex = pageIndex(from: item),
                  sourceIndex != index
            else { return false }
            startPageMutation {
                await model.movePage(
                    recordID: recordID,
                    from: sourceIndex,
                    to: index
                )
            }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(
            "Drag to reorder this page".localizedUI
        )
    }

    private func tileAction(
        _ label: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPageMutationBusy)
        .accessibilityLabel(label.localizedUI)
    }

    private func pageActionMenu(
        index: Int,
        pageCount: Int
    ) -> some View {
        Menu {
            Button {
                startPageMutation {
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
                startPageMutation {
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
                startPageMutation {
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
                startPageMutation {
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
                startPageMutation {
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
                startPageMutation {
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
                startPageMutation {
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
                startPageMutation {
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
                pendingDeletionRevisionID =
                    model.record(id: recordID)?.contentRevisionID
                pendingDeleteIndex = index
            } label: {
                Label("Remove Page", systemImage: "trash")
            }
            .disabled(pageCount == 1)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PPColor.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPageMutationBusy)
        .accessibilityLabel("More page actions".localizedUI)
        .accessibilityValue(
            AppLocalization.format("Page %lld", index + 1)
        )
    }

    private var extractionBar: some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(VStackLayout(spacing: PPSpacing.medium))
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

        return layout {
            Button {
                isPresentingPageSelection = true
            } label: {
                Image(systemName: "checklist")
                    .frame(width: 20, height: 20)
            }
            .confirmationDialog(
                "Select pages",
                isPresented: $isPresentingPageSelection,
                titleVisibility: .visible
            ) {
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
                Button("Cancel", role: .cancel) {}
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.textPrimary))
            .accessibilityIdentifier("pageSelectionMenu")
            .accessibilityLabel("Page selection".localizedUI)
            .accessibilityValue(
                AppLocalization.format(
                    "%lld pages selected",
                    selectedIndices.count
                )
            )
            .help("Page selection".localizedUI)
            .disabled(isPageMutationBusy)

            Button {
                isPresentingPageActions = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 20, height: 20)
            }
            .confirmationDialog(
                "Page actions",
                isPresented: $isPresentingPageActions,
                titleVisibility: .visible
            ) {
                if !startInSelectionMode {
                    Button {
                        extractSelectedPages()
                    } label: {
                        Label(
                            "Extract to New PDF",
                            systemImage: "doc.on.doc"
                        )
                    }
                    Divider()
                }

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
                    moveSelectedPages(toBeginning: true)
                } label: {
                    Label("Move selected pages to beginning".localizedUI, systemImage: "arrow.up.to.line")
                }
                .disabled(!canMoveSelectedPages(toBeginning: true))

                Button {
                    moveSelectedPages(toBeginning: false)
                } label: {
                    Label("Move selected pages to end".localizedUI, systemImage: "arrow.down.to.line")
                }
                .disabled(!canMoveSelectedPages(toBeginning: false))

                Button {
                    let indices = selectedIndices
                    startConfirmedPageMutation {
                        await model.duplicatePages(
                            recordID: recordID,
                            indices: indices
                        )
                    } onCommitted: {
                        selectedIndices = duplicatedPageIndices(
                            for: indices
                        )
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
                    startPageMutation {
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
                    startPageMutation {
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
                    requestBulkPageDeletion()
                } label: {
                    Label("Remove Pages", systemImage: "trash")
                }
                .disabled(
                    selectedIndices.count
                        >= (model.record(id: recordID)?
                            .profile.pageCount ?? 0)
                )
                Button("Cancel", role: .cancel) {}
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.textPrimary))
            .accessibilityIdentifier("pageSelectionActions")
            .accessibilityLabel("Page actions".localizedUI)
            .accessibilityValue(
                AppLocalization.format(
                    "%lld pages selected",
                    selectedIndices.count
                )
            )
            .help("Page actions".localizedUI)
            .disabled(
                selectedIndices.isEmpty
                    || isPageMutationBusy
            )
            .accessibilityHint(pageSelectionActionsHint)

            if !startInSelectionMode,
               !selectedIndices.isEmpty {
                Button(role: .destructive) {
                    requestBulkPageDeletion()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.rose))
                .disabled(
                    isPageMutationBusy
                        || selectedIndices.count
                            >= (model.record(id: recordID)?
                                .profile.pageCount ?? 0)
                )
                .accessibilityLabel(
                    "Remove selected pages".localizedUI
                )
                .accessibilityHint(
                    "Asks for confirmation before changing the private working copy."
                        .localizedUI
                )
                .accessibilityIdentifier("removeSelectedOrganizerPages")
            }

            Button {
                if startInSelectionMode {
                    extractSelectedPages()
                } else {
                    endPageSelection()
                }
            } label: {
                Label(
                    pageSelectionPrimaryTitle,
                    systemImage: startInSelectionMode
                        ? "doc.on.doc"
                        : "checkmark"
                )
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(
                isPageMutationBusy
                    || (
                        startInSelectionMode
                            && selectedIndices.isEmpty
                    )
            )
            .accessibilityIdentifier(
                startInSelectionMode
                    ? "extractPagesButton"
                    : "finishPageSelection"
            )
            .accessibilityHint(pageSelectionPrimaryHint)
        }
        .padding(PPSpacing.regular)
        .background(PPColor.canvas.opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.6)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var organizerCompletionBar: some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(
                HStackLayout(spacing: PPSpacing.medium)
            )
        return layout {
            Button {
                beginPageSelection()
            } label: {
                Label("Select Pages", systemImage: "checklist")
            }
            .buttonStyle(PPQuietButtonStyle())
            .accessibilityIdentifier("selectOrganizerPages")

            Button {
                onPrepare()
            } label: {
                Label("Review & Share", systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .accessibilityHint(
                "Continues to final checks before sharing"
                    .localizedUI
            )
            .accessibilityIdentifier("finishOrganizingPages")
        }
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.6)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var isPageMutationBusy: Bool {
        mutationTask != nil || model.isProcessing(recordID)
    }

    private var pageSelectionPrimaryTitle: String {
        if startInSelectionMode {
            return selectedIndices.isEmpty
                ? "Choose Pages".localizedUI
                : AppLocalization.format(
                    "Extract %lld",
                    selectedIndices.count
                )
        }
        guard !selectedIndices.isEmpty else {
            return "Done Selecting".localizedUI
        }
        return AppLocalization.format(
            "Done Selecting · %lld",
            selectedIndices.count
        )
    }

    private var pageSelectionActionsHint: String {
        if isPageMutationBusy {
            return "Wait for the current page update to finish."
                .localizedUI
        }
        if selectedIndices.isEmpty {
            return "Select at least one page first.".localizedUI
        }
        return "Opens actions for the selected pages.".localizedUI
    }

    private var pageSelectionPrimaryHint: String {
        if isPageMutationBusy {
            return "Wait for the current page update to finish."
                .localizedUI
        }
        if startInSelectionMode, selectedIndices.isEmpty {
            return "Select at least one page to create a separate PDF."
                .localizedUI
        }
        if startInSelectionMode {
            return "Creates a separate PDF from the selected pages."
                .localizedUI
        }
        return "Keeps the current selection and returns to page actions."
            .localizedUI
    }

    private func interruptPageMutation(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            mutationGeneration = UUID()
            pageMutationStopRequested = false
        } else {
            guard mutationTask != nil,
                  !pageMutationStopRequested
            else { return }
            pageMutationStopRequested = true
        }
        mutationTask?.cancel()
        if invalidateResult {
            mutationTask = nil
        }
    }

    private func requestBulkPageDeletion() {
        pendingBulkDeleteIndices = selectedIndices
        pendingDeletionRevisionID =
            model.record(id: recordID)?.contentRevisionID
        isConfirmingBulkDelete = true
    }

    private func deletionTargetsCurrentRevision() -> Bool {
        guard let pendingDeletionRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == pendingDeletionRevisionID
        else {
            pendingDeleteIndex = nil
            pendingBulkDeleteIndices = []
            presentPageMutationError(
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            )
            return false
        }
        return true
    }

    private func startPageMutation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        guard mutationTask == nil,
              !model.isProcessing(recordID),
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        pageMutationErrorMessage = nil
        pageMutationStopRequested = false
        let sourceRevisionID = model.record(id: recordID)?
            .contentRevisionID
        let generation = UUID()
        mutationGeneration = generation
        mutationTask = Task { @MainActor in
            defer {
                if mutationGeneration == generation {
                    mutationTask = nil
                    pageMutationStopRequested = false
                }
            }
            guard mutationGeneration == generation,
                  !Task.isCancelled,
                  model.record(id: recordID)?.contentRevisionID == sourceRevisionID
            else { return }
            await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await operation()
            }
            guard mutationGeneration == generation else { return }
            locallyCommittedRevisionID =
                model.record(id: recordID)?.contentRevisionID
            let wasStopped =
                pageMutationStopRequested || Task.isCancelled
            guard wasStopped else { return }
            let committed =
                sourceRevisionID != nil
                    && model.record(id: recordID)?
                        .contentRevisionID != sourceRevisionID
            model[noticeFor: paperPathSceneID] = (
                committed
                    ? "Page update finished before stopping · changes kept"
                    : "Page update stopped · working copy unchanged"
            ).localizedUI
        }
    }

    private func startConfirmedPageMutation(
        _ operation: @escaping @MainActor () async -> Bool,
        onCommitted: @escaping @MainActor () -> Void
    ) {
        guard mutationTask == nil,
              !model.isProcessing(recordID),
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        pageMutationErrorMessage = nil
        pageMutationStopRequested = false
        let sourceRevisionID = model.record(id: recordID)?.contentRevisionID
        let generation = UUID()
        mutationGeneration = generation
        mutationTask = Task { @MainActor in
            defer {
                if mutationGeneration == generation {
                    mutationTask = nil
                    pageMutationStopRequested = false
                }
            }
            guard mutationGeneration == generation,
                  !Task.isCancelled,
                  model.record(id: recordID)?.contentRevisionID == sourceRevisionID
            else { return }
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await operation()
            }
            guard mutationGeneration == generation else { return }
            if succeeded {
                locallyCommittedRevisionID =
                    model.record(id: recordID)?.contentRevisionID
            }
            let wasStopped =
                pageMutationStopRequested || Task.isCancelled
            if succeeded {
                onCommitted()
            }
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    succeeded
                        ? "Page update finished before stopping · changes kept"
                        : "Page update stopped · working copy unchanged"
                ).localizedUI
                return
            }
            if !succeeded {
                presentPageMutationError(
                    "Page update failed. Review the selection and try again."
                        .localizedUI
                )
            }
        }
    }

    private func selectedPageOrder(toBeginning: Bool) -> [Int] {
        let count = model.record(id: recordID)?.profile.pageCount ?? 0
        let pages = Array(0..<count)
        let selected = pages.filter { selectedIndices.contains($0) }
        let remaining = pages.filter { !selectedIndices.contains($0) }
        return toBeginning ? selected + remaining : remaining + selected
    }

    private func canMoveSelectedPages(toBeginning: Bool) -> Bool {
        let count = model.record(id: recordID)?.profile.pageCount ?? 0
        return !selectedIndices.isEmpty && !isPageMutationBusy
            && selectedPageOrder(toBeginning: toBeginning) != Array(0..<count)
    }

    private func moveSelectedPages(toBeginning: Bool) {
        guard canMoveSelectedPages(toBeginning: toBeginning) else { return }
        let order = selectedPageOrder(toBeginning: toBeginning)
        let selection = selectedIndices
        let updatedSelection = Set(order.indices.filter { selection.contains(order[$0]) })
        startConfirmedPageMutation {
            await model.reorderPages(
                recordID: recordID,
                order: order,
                label: (toBeginning
                    ? "Move selected pages to beginning"
                    : "Move selected pages to end").localizedUI
            )
        } onCommitted: {
            selectedIndices = updatedSelection
        }
    }

    private func completePageRangeSelection() {
        guard let request = pendingPageRange else { return }
        pendingPageRange = nil
        guard scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable,
              let record = model.record(id: recordID),
              record.contentRevisionID == request.sourceRevisionID,
              record.profile.pageCount > 0
        else {
            presentPageMutationError(
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            )
            return
        }
        guard !request.indices.isEmpty,
              request.indices.allSatisfy({ (0..<record.profile.pageCount).contains($0) })
        else { return }
        selectedIndices = request.indices
    }

    private func completePageCopySelection() {
        guard let pendingPageCopy else { return }
        self.pendingPageCopy = nil
        guard scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable,
              !pendingPageCopy.pageIndices.isEmpty,
              model.record(id: recordID)?.contentRevisionID
                == pendingPageCopy.sourceRevisionID,
              let destination = model.record(
                id: pendingPageCopy.destinationID
              ),
              destination.isWorkingCopy,
              !destination.profile.isLocked,
              destination.contentRevisionID
                == pendingPageCopy.destinationRevisionID
        else {
            presentPageMutationError(
                "The source or destination PDF changed. Review the pages and choose again."
                    .localizedUI
            )
            return
        }
        startConfirmedPageMutation {
            await model.copyPages(
                from: recordID,
                indices: pendingPageCopy.pageIndices,
                to: pendingPageCopy.destinationID
            )
        } onCommitted: {
            selectedIndices.removeAll()
            isSelecting = false
        }
    }

    private func discardPendingPageSelectionHandoffs() {
        pendingPageRange = nil
        pendingPageCopy = nil
        isSelectingRange = false
        isChoosingDestination = false
    }

    private func extractSelectedPages() {
        guard mutationTask == nil,
              !model.isProcessing(recordID),
              !selectedIndices.isEmpty,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable,
              let sourceRevisionID = model.record(id: recordID)?
                .contentRevisionID
        else { return }
        pageMutationErrorMessage = nil
        pageMutationStopRequested = false
        let indices = selectedIndices
        let generation = UUID()
        mutationGeneration = generation
        mutationTask = Task { @MainActor in
            defer {
                if mutationGeneration == generation {
                    mutationTask = nil
                    pageMutationStopRequested = false
                }
            }
            guard mutationGeneration == generation,
                  !Task.isCancelled,
                  model.record(id: recordID)?.contentRevisionID
                    == sourceRevisionID
            else { return }
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.extractPages(
                    recordID: recordID,
                    indices: indices,
                    expectedContentRevisionID: sourceRevisionID
                )
            }
            guard mutationGeneration == generation else { return }
            let wasStopped =
                pageMutationStopRequested || Task.isCancelled
            mutationTask = nil
            pageMutationStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    created == nil
                        ? "Page extraction stopped"
                        : "Copy finished before stopping · copy kept in Library"
                ).localizedUI
                return
            }
            guard let created else {
                presentPageMutationError(
                    "The selected pages could not be extracted. Your selection is unchanged."
                        .localizedUI
                )
                return
            }
            isSelecting = false
            selectedIndices.removeAll()
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func presentPageMutationError(_ message: String) {
        pageMutationErrorMessage = message
        pageMutationErrorFeedback += 1
    }

    private func toggleSelection(_ index: Int) {
        if selectedIndices.contains(index) {
            selectedIndices.remove(index)
        } else {
            selectedIndices.insert(index)
        }
    }

    private func beginPageSelection() {
        withAnimation(
            reduceMotion ? nil : .easeOut(duration: 0.18)
        ) {
            isSelecting = true
            selectedIndices.removeAll()
        }
    }

    private func endPageSelection() {
        withAnimation(
            reduceMotion ? nil : .easeOut(duration: 0.18)
        ) {
            isSelecting = false
            selectedIndices.removeAll()
        }
    }

    private var hasCopyDestination: Bool {
        model.documents.contains {
            $0.id != recordID
                && $0.isWorkingCopy
                && !$0.profile.isLocked
        }
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
    let pages: [ScanPageImage]
    let fallbackOptions: ScanProcessingOptions
    let displayName: String
    let initialPageIndex: Int

    init(
        images: [UIImage],
        initialOptions: ScanProcessingOptions,
        displayName: String
    ) {
        pages = images.map {
            ScanPageImage(
                image: $0,
                processingOptions: initialOptions
            )
        }
        fallbackOptions = initialOptions
        self.displayName = displayName
        initialPageIndex = 0
    }

    init(
        pages: [ScanPageImage],
        fallbackOptions: ScanProcessingOptions,
        displayName: String,
        initialPageIndex: Int = 0
    ) {
        self.pages = pages
        self.fallbackOptions = fallbackOptions
        self.displayName = displayName
        self.initialPageIndex = pages.isEmpty
            ? 0
            : min(max(0, initialPageIndex), pages.count - 1)
    }
}

private struct PendingReviewedReplacementSource {
    let pages: [ScanPageImage]
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let destinationRecordID: UUID
    let destinationPageIndex: Int
    let onComplete: () -> Void

    @State private var sourceRecordID: UUID?
    @State private var sourcePageIndex = 0
    @State private var sourceMode = SourceMode.library
    @State private var isImportingExternalSource = false
    @State private var isPreparingExternalSource = false
    @State private var externalSource: PDFExternalPageSource?
    @State private var sourceGeometryItem:
        PDFPagePreparationItem?
    @State private var destinationGeometryItem:
        PDFPagePreparationItem?
    @State private var sourceGeometryRevisionID: UUID?
    @State private var destinationGeometryRevisionID: UUID?
    @State private var externalPreparationTask:
        Task<Void, Never>?
    @State private var externalPreparationGeneration = UUID()
    @State private var replacementTask: Task<Void, Never>?
    @State private var replacementGeneration = UUID()
    @State private var replacementStopRequested = false
    @State private var replacementCommittedAfterStop = false
    @State private var replacementErrorMessage: String?
    @State private var replacementErrorFeedback = 0
    @State private var photoItem: PhotosPickerItem?
    @State private var isPresentingScanner = false
    @State private var pendingCameraScanReview:
        ReplacementScanReviewSession?
    @State private var replacementScanReview:
        ReplacementScanReviewSession?
    @State private var suspendedReplacementScanReview:
        ReplacementScanReviewSession?
    @State private var pendingReviewedReplacementSource:
        PendingReviewedReplacementSource?
    @State private var replacementReviewTransitionTask:
        Task<Void, Never>?
    @State private var replacementReviewTransitionGeneration = UUID()

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
                        if let replacementErrorMessage {
                            replacementErrorBanner(
                                replacementErrorMessage
                            )
                        }
                        sourcePageGrid
                    }
                    .frame(maxWidth: 920)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
                .disabled(replacementTask != nil)

                replaceCommand
            }
            .background(PPColor.canvas)
            .navigationTitle("Replace page".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(replacementToolbarTitle) {
                        if replacementTask != nil {
                            stopReplacementOperation()
                        } else if externalPreparationTask != nil
                                    || isPreparingExternalSource {
                            stopExternalSourcePreparation()
                        } else if replacementCommittedAfterStop {
                            onComplete()
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(replacementStopRequested)
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .accessibilityAction(.escape) {
            if replacementTask != nil {
                stopReplacementOperation()
            } else if externalPreparationTask != nil
                        || isPreparingExternalSource {
                stopExternalSourcePreparation()
            } else if replacementCommittedAfterStop {
                onComplete()
            } else {
                dismiss()
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
        .task(id: destinationGeometryRequestID) {
            destinationGeometryItem = nil
            destinationGeometryRevisionID = nil
            let revision = model.record(id: destinationRecordID)?
                .contentRevisionID
            let loaded = await model.pageGeometryItem(
                recordID: destinationRecordID,
                pageIndex: destinationPageIndex
            )
            guard !Task.isCancelled,
                  model.record(id: destinationRecordID)?
                    .contentRevisionID == revision
            else { return }
            destinationGeometryItem = loaded
            destinationGeometryRevisionID = revision
        }
        .task(id: sourceGeometryRequestID) {
            sourceGeometryItem = nil
            sourceGeometryRevisionID = nil
            switch sourceMode {
            case .library:
                guard let sourceRecordID else { return }
                let revision = model.record(id: sourceRecordID)?
                    .contentRevisionID
                let loaded = await model.pageGeometryItem(
                    recordID: sourceRecordID,
                    pageIndex: sourcePageIndex
                )
                guard !Task.isCancelled,
                      sourceMode == .library,
                      self.sourceRecordID == sourceRecordID,
                      model.record(id: sourceRecordID)?
                        .contentRevisionID == revision
                else { return }
                sourceGeometryItem = loaded
                sourceGeometryRevisionID = revision
            case .files, .photos, .camera:
                guard let externalSource else { return }
                let loaded = await model.pageGeometryItem(
                    source: externalSource,
                    pageIndex: sourcePageIndex
                )
                guard !Task.isCancelled,
                      sourceMode != .library,
                      self.externalSource?.id == externalSource.id
                else { return }
                sourceGeometryItem = loaded
            }
        }
        .fileImporter(
            isPresented: $isImportingExternalSource,
            allowedContentTypes: [.pdf]
        ) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result {
                    model.present(error, in: paperPathSceneID)
                }
                return
            }
            prepareExternalSource(url)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            preparePhotoSource(item)
        }
        .fullScreenCover(
            isPresented: $isPresentingScanner,
            onDismiss: presentPendingReplacementScanReview
        ) {
            DocumentScannerView(
                maximumPageCount: 24,
                onComplete: { images in
                    pendingCameraScanReview =
                        ReplacementScanReviewSession(
                            images: images,
                            initialOptions: .document,
                            displayName:
                                "Reviewed Camera Scan".localizedUI
                        )
                    isPresentingScanner = false
                },
                onCancel: {
                    pendingCameraScanReview = nil
                    isPresentingScanner = false
                },
                onError: { error in
                    pendingCameraScanReview = nil
                    isPresentingScanner = false
                    model.present(error, in: paperPathSceneID)
                }
            )
            .ignoresSafeArea()
        }
        .sheet(
            item: $replacementScanReview,
            onDismiss: completeReviewedReplacementHandoff
        ) { session in
            ScanReviewView(
                pages: session.pages,
                fallbackOptions: session.fallbackOptions,
                purpose: .replacePage,
                initialPageIndex: session.initialPageIndex,
                onSuspend: { pages, pageIndex in
                    suspendedReplacementScanReview =
                        ReplacementScanReviewSession(
                            pages: pages,
                            fallbackOptions: session.fallbackOptions,
                            displayName: session.displayName,
                            initialPageIndex: pageIndex
                        )
                    replacementScanReview = nil
                }
            ) { pages in
                suspendedReplacementScanReview = nil
                pendingReviewedReplacementSource =
                    PendingReviewedReplacementSource(
                        pages: pages,
                        displayName: session.displayName
                    )
                replacementScanReview = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                presentPendingReplacementScanReview()
                resumeSuspendedReplacementScanReview()
                completeReviewedReplacementHandoff()
            } else if phase == .background {
                stopProtectedReplacementWork(
                    preservesSuspendedReview: true
                )
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            stopProtectedReplacementWork()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            presentPendingReplacementScanReview()
            resumeSuspendedReplacementScanReview()
            completeReviewedReplacementHandoff()
        }
        .onDisappear {
            stopProtectedReplacementWork()
            pendingReviewedReplacementSource = nil
        }
        .interactiveDismissDisabled(hasActiveReplacementOperation)
        .sensoryFeedback(
            .error,
            trigger: replacementErrorFeedback
        )
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

    private var destinationGeometryRequestID: String {
        "\(destinationRecordID.uuidString)-\(destinationPageIndex)-\(model.refreshToken(for: destinationRecordID))"
    }

    private var sourceGeometryRequestID: String {
        let revision = sourceRecordID.map {
            model.refreshToken(for: $0)
        } ?? 0
        let sourceID = sourceRecordID?.uuidString
            ?? externalSource?.id.uuidString
            ?? "none"
        return "\(sourceMode.rawValue)-\(sourceID)-\(sourcePageIndex)-\(revision)"
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
                if dynamicTypeSize.ppPrefersExpandedLayout {
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
                replacementErrorMessage = nil
                sourcePageIndex = 0
                sourceGeometryItem = nil
            }
            .onChange(of: sourceMode) { _, _ in
                replacementErrorMessage = nil
                externalPreparationGeneration = UUID()
                externalPreparationTask?.cancel()
                externalPreparationTask = nil
                discardPreparedSource()
                isPreparingExternalSource = false
                replacementScanReview = nil
                suspendedReplacementScanReview = nil
                pendingCameraScanReview = nil
                pendingReviewedReplacementSource = nil
                if sourceMode != .photos {
                    photoItem = nil
                }
                sourcePageIndex = 0
                sourceGeometryItem = nil
            }
            if sourceMode == .library, candidates.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        unavailableLibrarySourceMessage
                        Spacer(minLength: PPSpacing.small)
                        chooseReplacementFileButton
                    }
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        unavailableLibrarySourceMessage
                        chooseReplacementFileButton
                    }
                }
            }
        }
    }

    private var unavailableLibrarySourceMessage: some View {
        Label(
            "No other unlocked private copy is available.",
            systemImage: "lock.doc"
        )
        .font(.caption)
        .foregroundStyle(PPColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var chooseReplacementFileButton: some View {
        Button {
            sourceMode = .files
        } label: {
            Label("Choose from Files", systemImage: "folder")
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
        .accessibilityHint(
            "Switches the replacement source to a temporary PDF from Files."
                .localizedUI
        )
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
                    sourcePreparationIndicator
                } else if let externalSource {
                    sourceSummary(externalSource)
                }
            case .photos:
                let photoButtonTitle = externalSource == nil
                    ? "Choose Photo"
                    : "Choose Another"
                PhotosPicker(
                    selection: $photoItem,
                    matching: .images
                ) {
                    Label(
                        photoButtonTitle,
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
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                )
            Text(
                "\(source.pageCount) pages · \(source.formattedSize)"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(PPColor.textSecondary)
        }
    }

    private var sourceModeControl: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
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
            maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
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
                            replacementErrorMessage = nil
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
                            .overlay(alignment: .topTrailing) {
                                if index == sourcePageIndex {
                                    Image(
                                        systemName: "checkmark.circle.fill"
                                    )
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(PPColor.mint)
                                    .padding(PPSpacing.xSmall)
                                    .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            AppLocalization.format(
                                "Replacement source page %lld",
                                index + 1
                            )
                        )
                        .accessibilityValue(
                            (
                                index == sourcePageIndex
                                    ? "Selected"
                                    : "Not selected"
                            ).localizedUI
                        )
                        .accessibilityHint(
                            "Uses this page in the replacement preview."
                                .localizedUI
                        )
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
                        ? "Choose a PDF from Files. It is removed after replacement."
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
        guard let destination = destinationGeometryItem,
              let source = sourceGeometryItem
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

    private func replacementErrorBanner(
        _ message: String
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Image(systemName: "exclamationmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.rose)
                .frame(width: 22)
            Text(message.localizedUI)
                .font(.caption)
                .foregroundStyle(PPColor.rose)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                replacementErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.textSecondary)
            .accessibilityLabel(
                "Dismiss replacement error".localizedUI
            )
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("pageReplacementError")
    }

    private var replaceCommand: some View {
        Button {
            if replacementTask != nil {
                stopReplacementOperation()
            } else if replacementCommittedAfterStop {
                onComplete()
            } else {
                replacePage()
            }
        } label: {
            Label(
                replacementCommandTitle,
                systemImage: replacementCommittedAfterStop
                    ? "checkmark"
                    : replacementTask != nil
                        ? "xmark.circle.fill"
                        : "arrow.triangle.2.circlepath"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            replacementStopRequested
                || (
                    replacementTask == nil
                        && (
                            effectiveSourceURL == nil
                                || isPreparingExternalSource
                                || destinationGeometryItem == nil
                                || sourceGeometryItem == nil
                                || model.isProcessing(
                                    destinationRecordID
                                )
                        )
                )
        )
        .accessibilityHint(replacementCommandHint)
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var replacementCommandTitle: String {
        if replacementStopRequested {
            return "Stopping replacement".localizedUI
        }
        if replacementCommittedAfterStop {
            return "Done".localizedUI
        }
        if replacementTask != nil {
            return "Stop replacing".localizedUI
        }
        return AppLocalization.format(
                        "Replace with page %lld",
                        sourcePageIndex + 1
        )
    }

    private var replacementCommandHint: String {
        if replacementStopRequested {
            return "Waiting for the current replacement step to stop."
                .localizedUI
        }
        if replacementCommittedAfterStop {
            return "Returns to the updated working copy.".localizedUI
        }
        if replacementTask != nil {
            return "Stops before the prepared page is committed"
                .localizedUI
        }
        return "Replaces only this private working copy"
            .localizedUI
    }

    private var replacementToolbarTitle: String {
        if replacementStopRequested {
            return "Stopping".localizedUI
        }
        if replacementCommittedAfterStop {
            return "Done".localizedUI
        }
        if replacementTask != nil
            || externalPreparationTask != nil
            || isPreparingExternalSource {
            return "Stop".localizedUI
        }
        return "Cancel".localizedUI
    }

    private var hasActiveReplacementOperation: Bool {
        replacementTask != nil
            || externalPreparationTask != nil
            || isPreparingExternalSource
    }

    private func replacePage() {
        guard replacementTask == nil,
              !replacementCommittedAfterStop,
              !model.isProcessing(destinationRecordID),
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable,
              let destinationRevisionID =
                destinationGeometryRevisionID,
              model.record(id: destinationRecordID)?
                .contentRevisionID == destinationRevisionID,
              destinationGeometryItem != nil,
              sourceGeometryItem != nil
        else { return }
        replacementErrorMessage = nil
        replacementStopRequested = false
        replacementCommittedAfterStop = false
        let generation = UUID()
        replacementGeneration = generation
        replacementTask = Task { @MainActor in
            defer {
                if replacementGeneration == generation {
                    replacementTask = nil
                    replacementStopRequested = false
                }
            }
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                switch sourceMode {
                case .library:
                    guard let sourceRecordID,
                          let sourceRevisionID =
                            sourceGeometryRevisionID,
                          model.record(id: sourceRecordID)?
                            .contentRevisionID
                            == sourceRevisionID
                    else { return false }
                    return await model.replacePage(
                        recordID: destinationRecordID,
                        index: destinationPageIndex,
                        from: sourceRecordID,
                        sourceIndex: sourcePageIndex,
                        expectedDestinationContentRevisionID:
                            destinationRevisionID,
                        expectedSourceContentRevisionID:
                            sourceRevisionID
                    )
                case .files, .photos, .camera:
                    guard let externalSource else { return false }
                    return await model.replacePage(
                        recordID: destinationRecordID,
                        index: destinationPageIndex,
                        from: externalSource,
                        sourceIndex: sourcePageIndex,
                        expectedContentRevisionID:
                            destinationRevisionID
                    )
                }
            }
            guard replacementGeneration == generation else { return }
            let wasStopped =
                replacementStopRequested || Task.isCancelled
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    succeeded
                        ? "Page replacement finished before stopping · change kept"
                        : "Page replacement stopped · working copy unchanged"
                ).localizedUI
                replacementCommittedAfterStop = succeeded
                return
            }
            guard succeeded else {
                replacementErrorMessage =
                    "The page was not replaced. Review the source and try again."
                        .localizedUI
                replacementErrorFeedback += 1
                return
            }
            onComplete()
        }
    }

    private func stopReplacementOperation(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            replacementGeneration = UUID()
        } else if replacementTask != nil {
            replacementStopRequested = true
        }
        replacementTask?.cancel()
        if invalidateResult {
            replacementTask = nil
            replacementStopRequested = false
        }
    }

    private func stopExternalSourcePreparation() {
        externalPreparationGeneration = UUID()
        externalPreparationTask?.cancel()
        externalPreparationTask = nil
        isPreparingExternalSource = false
        photoItem = nil
        replacementErrorMessage = nil
        model[noticeFor: paperPathSceneID] = "Source preparation stopped".localizedUI
        resumeSuspendedReplacementScanReview()
    }

    private func prepareExternalSource(_ url: URL) {
        let generation = beginExternalPreparation()
        externalPreparationTask = Task { @MainActor in
            let prepared = await model.prepareExternalPageSource(
                from: url
            )
            guard !Task.isCancelled,
                  externalPreparationGeneration == generation,
                  sourceMode == .files
            else {
                if let prepared {
                    model.discardExternalPageSource(prepared)
                }
                return
            }
            externalSource = prepared
            sourcePageIndex = 0
            sourceGeometryItem = prepared?.assessment.pages.first
            finishExternalPreparation(generation)
        }
    }

    @ViewBuilder
    private var sourcePreparationStatus: some View {
        if isPreparingExternalSource {
            sourcePreparationIndicator
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

    private var sourcePreparationIndicator: some View {
        HStack(spacing: PPSpacing.xSmall) {
            ProgressView()
                .controlSize(.small)
            Text("Preparing source".localizedUI)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func preparePhotoSource(_ item: PhotosPickerItem) {
        let generation = beginExternalPreparation()
        externalPreparationTask = Task { @MainActor in
            let transfer: ProtectedPhotoTransfer?
            do {
                transfer = try await item.loadTransferable(
                    type: ProtectedPhotoTransfer.self
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      externalPreparationGeneration == generation,
                      sourceMode == .photos,
                      scenePhase == .active,
                      UIApplication.shared.isProtectedDataAvailable
                else { return }
                photoItem = nil
                finishExternalPreparation(generation)
                if LocalFileSecurity.isInsufficientStorageError(error) {
                    model.present(
                        PaperPathError.insufficientStorage,
                        in: paperPathSceneID
                    )
                    return
                }
                model.present(
                    PaperPathError.unreadableImage,
                    in: paperPathSceneID
                )
                return
            }
            guard !Task.isCancelled,
                  externalPreparationGeneration == generation,
                  sourceMode == .photos,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            guard let transfer else {
                photoItem = nil
                finishExternalPreparation(generation)
                model.present(
                    PaperPathError.unreadableImage,
                    in: paperPathSceneID
                )
                return
            }
            defer { transfer.discard() }
            guard transfer.byteCount <= 32 * 1_024 * 1_024,
                  let image = await Self.downsampledImage(
                    from: transfer.fileURL
                  )
            else {
                guard !Task.isCancelled,
                      externalPreparationGeneration == generation,
                      sourceMode == .photos
                else { return }
                photoItem = nil
                finishExternalPreparation(generation)
                model.present(
                    PaperPathError.unreadableImage,
                    in: paperPathSceneID
                )
                return
            }
            guard !Task.isCancelled,
                  externalPreparationGeneration == generation,
                  sourceMode == .photos,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            isPreparingExternalSource = false
            photoItem = nil
            await Task.yield()
            guard !Task.isCancelled,
                  externalPreparationGeneration == generation,
                  sourceMode == .photos
            else { return }
            replacementScanReview = ReplacementScanReviewSession(
                images: [image],
                initialOptions: .original,
                displayName: "Reviewed Photo Page".localizedUI
            )
            finishExternalPreparation(generation)
        }
    }

    private func prepareImageSource(
        _ pages: [ScanPageImage],
        displayName: String
    ) {
        let expectedMode = sourceMode
        guard expectedMode == .photos || expectedMode == .camera else {
            return
        }
        let generation = beginExternalPreparation()
        externalPreparationTask = Task { @MainActor in
            let prepared = await model.prepareImagePageSource(
                pages: pages,
                displayName: displayName
            )
            guard !Task.isCancelled,
                  externalPreparationGeneration == generation,
                  sourceMode == expectedMode
            else {
                if let prepared {
                    model.discardExternalPageSource(prepared)
                }
                return
            }
            guard let prepared else {
                finishExternalPreparation(generation)
                resumeSuspendedReplacementScanReview()
                return
            }
            externalSource = prepared
            sourcePageIndex = 0
            sourceGeometryItem = prepared.assessment.pages.first
            suspendedReplacementScanReview = nil
            finishExternalPreparation(generation)
        }
    }

    private func presentPendingReplacementScanReview() {
        guard let session = pendingCameraScanReview,
              replacementScanReview == nil,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable,
              sourceMode == .camera
        else { return }
        let sessionID = session.id
        replacementReviewTransitionTask?.cancel()
        let generation = UUID()
        replacementReviewTransitionGeneration = generation
        replacementReviewTransitionTask = Task { @MainActor in
            defer {
                if replacementReviewTransitionGeneration == generation {
                    replacementReviewTransitionTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  replacementReviewTransitionGeneration == generation,
                  pendingCameraScanReview?.id == sessionID,
                  replacementScanReview == nil,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  sourceMode == .camera
            else { return }
            pendingCameraScanReview = nil
            replacementScanReview = session
        }
    }

    private func resumeSuspendedReplacementScanReview() {
        guard let session = suspendedReplacementScanReview,
              replacementScanReview == nil,
              pendingReviewedReplacementSource == nil,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable,
              sourceMode == .photos || sourceMode == .camera
        else { return }
        let sessionID = session.id
        replacementReviewTransitionTask?.cancel()
        let generation = UUID()
        replacementReviewTransitionGeneration = generation
        replacementReviewTransitionTask = Task { @MainActor in
            defer {
                if replacementReviewTransitionGeneration == generation {
                    replacementReviewTransitionTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  replacementReviewTransitionGeneration == generation,
                  suspendedReplacementScanReview?.id == sessionID,
                  replacementScanReview == nil,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  sourceMode == .photos || sourceMode == .camera
            else { return }
            suspendedReplacementScanReview = nil
            replacementScanReview = session
            model[noticeFor: paperPathSceneID] =
                "Replacement review restored".localizedUI
        }
    }

    private func completeReviewedReplacementHandoff() {
        guard let source = pendingReviewedReplacementSource,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        replacementReviewTransitionTask?.cancel()
        let generation = UUID()
        replacementReviewTransitionGeneration = generation
        replacementReviewTransitionTask = Task { @MainActor in
            defer {
                if replacementReviewTransitionGeneration == generation {
                    replacementReviewTransitionTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  replacementReviewTransitionGeneration == generation,
                  pendingReviewedReplacementSource != nil,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            pendingReviewedReplacementSource = nil
            suspendedReplacementScanReview =
                ReplacementScanReviewSession(
                    pages: source.pages,
                    fallbackOptions: .document,
                    displayName: source.displayName
                )
            prepareImageSource(
                source.pages,
                displayName: source.displayName
            )
        }
    }

    private func beginExternalPreparation() -> UUID {
        externalPreparationTask?.cancel()
        let generation = UUID()
        externalPreparationGeneration = generation
        isPreparingExternalSource = true
        discardPreparedSource()
        return generation
    }

    private func finishExternalPreparation(_ generation: UUID) {
        guard externalPreparationGeneration == generation else {
            return
        }
        isPreparingExternalSource = false
        externalPreparationTask = nil
    }

    private func discardPreparedSource() {
        if let externalSource {
            model.discardExternalPageSource(externalSource)
            self.externalSource = nil
        }
        sourceGeometryItem = nil
    }

    private func stopProtectedReplacementWork(
        preservesSuspendedReview: Bool = false
    ) {
        replacementReviewTransitionGeneration = UUID()
        replacementReviewTransitionTask?.cancel()
        replacementReviewTransitionTask = nil
        externalPreparationGeneration = UUID()
        stopReplacementOperation(invalidateResult: true)
        externalPreparationTask?.cancel()
        externalPreparationTask = nil
        isPreparingExternalSource = false
        replacementStopRequested = false
        replacementCommittedAfterStop = false
        replacementErrorMessage = nil
        isImportingExternalSource = false
        isPresentingScanner = false
        if !preservesSuspendedReview {
            pendingCameraScanReview = nil
            suspendedReplacementScanReview = nil
            pendingReviewedReplacementSource = nil
            replacementScanReview = nil
        }
        photoItem = nil
        discardPreparedSource()
    }

    private func beginReplacementScan() {
        guard VNDocumentCameraViewController.isSupported else {
            model.present(
                PaperPathError.cameraUnavailable,
                in: paperPathSceneID
            )
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            model.presentCameraPermissionDenied(
                in: paperPathSceneID
            )
        case .authorized, .notDetermined:
            isPresentingScanner = true
        @unknown default:
            model.present(
                PaperPathError.cameraUnavailable,
                in: paperPathSceneID
            )
        }
    }

    nonisolated private static func downsampledImage(
        from fileURL: URL
    ) async -> UIImage? {
        let worker = Task.detached(
            priority: .userInitiated
        ) { () throws -> UIImage? in
            try Task.checkCancellation()
            let values = try? fileURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  let fileSize = values?.fileSize,
                  fileSize > 0,
                  fileSize <= 32 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithURL(
                      fileURL as CFURL,
                      [
                          kCGImageSourceShouldCache: false
                      ] as CFDictionary
                  ),
                  CGImageSourceGetCount(source) == 1,
                  let properties =
                    CGImageSourceCopyPropertiesAtIndex(
                        source,
                        0,
                        nil
                    ) as? [CFString: Any],
                  let width = (
                      properties[kCGImagePropertyPixelWidth]
                        as? NSNumber
                  )?.int64Value,
                  let height = (
                      properties[kCGImagePropertyPixelHeight]
                        as? NSNumber
                  )?.int64Value,
                  width > 0,
                  height > 0,
                  width <= 100_000,
                  height <= 100_000
            else { return nil }
            let pixels = width.multipliedReportingOverflow(by: height)
            guard !pixels.overflow,
                  pixels.partialValue <= 120_000_000
            else { return nil }
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            return UIImage(cgImage: cgImage)
        }
        return try? await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private struct PageRuleWorkbench: View {
    private enum NumberRule:
        String,
        CaseIterable,
        Identifiable,
        Sendable {
        case all
        case odd
        case even

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .odd: return "Odd"
            case .even: return "Even"
            }
        }
    }

    private enum OrientationRule:
        String,
        CaseIterable,
        Identifiable,
        Sendable {
        case any
        case portrait
        case landscape

        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: return "Any"
            case .portrait: return "Portrait"
            case .landscape: return "Landscape"
            }
        }
    }

    private enum PaperRule:
        String,
        CaseIterable,
        Identifiable,
        Sendable {
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

    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let recordID: UUID
    let currentSelection: Set<Int>
    let onSelect: (Set<Int>) -> Void
    let onReorder: ([Int], String) -> Void

    @State private var assessment: PDFPagePreparationAssessment?
    @State private var numberRule = NumberRule.all
    @State private var orientationRule = OrientationRule.any
    @State private var paperRule = PaperRule.any
    @State private var isLoading = false
    @State private var isCalculatingMatches = false
    @State private var analysisTask: Task<Void, Never>?
    @State private var matchingIndices: Set<Int> = []
    @State private var matchTask: Task<Void, Never>?
    @State private var matchGeneration = UUID()
    @State private var analysisGeneration = UUID()
    @State private var ruleRevisionID: UUID?
    @State private var assessmentErrorMessage: String?
    @State private var assessmentErrorFeedback = 0

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
                        commitSelection()
                    }
                    .disabled(
                        matchingIndices.isEmpty
                            || isCalculatingMatches
                            || !rulesTargetCurrentRevision
                    )
                }
            }
        }
        .onAppear {
            startAssessment()
            scheduleMatchCalculation()
        }
        .onChange(of: numberRule) { _, _ in
            scheduleMatchCalculation()
        }
        .onChange(of: orientationRule) { _, _ in
            scheduleMatchCalculation()
        }
        .onChange(of: paperRule) { _, _ in
            scheduleMatchCalculation()
        }
        .onChange(of: pageCount) { _, _ in
            scheduleMatchCalculation()
        }
        .onChange(of: contentRevisionID) { _, _ in
            interruptRuleAssessment()
            guard scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            startAssessment()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if assessment == nil, analysisTask == nil {
                    startAssessment()
                } else if analysisTask == nil {
                    scheduleMatchCalculation()
                }
            } else if phase == .background {
                interruptRuleAssessment()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptRuleAssessment()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            if assessment == nil, analysisTask == nil {
                startAssessment()
            } else if analysisTask == nil {
                scheduleMatchCalculation()
            }
        }
        .onDisappear {
            interruptRuleAssessment()
        }
        .sensoryFeedback(
            .error,
            trigger: assessmentErrorFeedback
        )
    }

    private var pageCount: Int {
        model.record(id: recordID)?.profile.pageCount ?? 0
    }

    private var contentRevisionID: UUID? {
        model.record(id: recordID)?.contentRevisionID
    }

    private var rulesTargetCurrentRevision: Bool {
        guard let ruleRevisionID else { return false }
        return contentRevisionID == ruleRevisionID
    }

    private var ruleHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "DETERMINISTIC RULES",
            title: "Select and arrange pages",
            detail: "Review every match before selection. Reordering keeps all pages.",
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
            let picker = Picker(
                "Page number",
                selection: $numberRule
            ) {
                ForEach(NumberRule.allCases) { rule in
                    Text(rule.title.localizedUI).tag(rule)
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
    }

    private var orientationRuleControl: some View {
        ruleControl("ORIENTATION") {
            let picker = Picker(
                "Orientation",
                selection: $orientationRule
            ) {
                ForEach(OrientationRule.allCases) { rule in
                    Text(rule.title.localizedUI).tag(rule)
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
                    .disabled(assessment == nil)
            } else {
                picker
                    .pickerStyle(.segmented)
                    .disabled(assessment == nil)
            }
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
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout
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
                detail: isLoading || isCalculatingMatches
                    ? "Reading page geometry on device"
                    : "Page numbers before any action",
                symbol: "number",
                count: matchingIndices.count,
                tint: PPColor.cyan
            )

            if isLoading || isCalculatingMatches {
                HStack(spacing: PPSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Inspecting page geometry".localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                }
                .frame(minHeight: 42)
            } else if let assessmentErrorMessage {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    Label(
                        assessmentErrorMessage.localizedUI,
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.rose)
                    .fixedSize(horizontal: false, vertical: true)
                    Button {
                        startAssessment()
                    } label: {
                        Label(
                            "Inspect Page Geometry Again",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.cyan)
                    )
                    .accessibilityIdentifier(
                        "retryPageRuleAssessment"
                    )
                }
                .padding(.vertical, PPSpacing.small)
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
                    commitReorder(
                        Array((0..<pageCount).reversed()),
                        "Reverse page order".localizedUI
                    )
                }
                arrangementAction(
                    "Odd then even",
                    detail: "1, 3, 5… then 2, 4, 6…",
                    symbol: "list.number"
                ) {
                    commitReorder(
                        groupedPageOrder(oddFirst: true),
                        "Group odd and even pages".localizedUI
                    )
                }
                arrangementAction(
                    "Even then odd",
                    detail: "2, 4, 6… then 1, 3, 5…",
                    symbol: "list.number.rtl"
                ) {
                    commitReorder(
                        groupedPageOrder(oddFirst: false),
                        "Group even and odd pages".localizedUI
                    )
                }
                arrangementAction(
                    "Interleave halves",
                    detail: "Alternate first and second stacks",
                    symbol: "square.2.layers.3d"
                ) {
                    commitReorder(
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
        .disabled(
            pageCount < 2
                || model.isProcessing(recordID)
                || !rulesTargetCurrentRevision
        )
    }

    private func commitSelection() {
        guard rulesTargetCurrentRevision else {
            refreshRulesForUpdatedPDF()
            return
        }
        onSelect(matchingIndices)
    }

    private func commitReorder(
        _ order: [Int],
        _ label: String
    ) {
        guard rulesTargetCurrentRevision else {
            refreshRulesForUpdatedPDF()
            return
        }
        onReorder(order, label)
    }

    private func refreshRulesForUpdatedPDF() {
        model[noticeFor: paperPathSceneID] =
            "The PDF changed before this action started. Review the updated PDF."
                .localizedUI
        startAssessment()
    }

    nonisolated private static func matchingIndices(
        pageCount: Int,
        pages: [PDFPagePreparationItem],
        numberRule: NumberRule,
        orientationRule: OrientationRule,
        paperRule: PaperRule
    ) -> Set<Int> {
        let needsGeometry = orientationRule != .any
            || paperRule != .any
        var itemsByPage: [Int: PDFPagePreparationItem] = [:]
        if needsGeometry {
            itemsByPage.reserveCapacity(pages.count)
            for (offset, item) in pages.enumerated() {
                if offset.isMultiple(of: 256),
                   Task.isCancelled {
                    return []
                }
                itemsByPage[item.pageIndex] = item
            }
        }
        var matches = Set<Int>()
        matches.reserveCapacity(
            numberRule == .all
                ? pageCount
                : (pageCount + 1) / 2
        )
        for index in 0..<pageCount {
            if index.isMultiple(of: 256),
               Task.isCancelled {
                return []
            }
            let numberMatches: Bool
            switch numberRule {
            case .all: numberMatches = true
            case .odd: numberMatches = index.isMultiple(of: 2)
            case .even: numberMatches = !index.isMultiple(of: 2)
            }
            guard numberMatches else { continue }
            guard needsGeometry else {
                matches.insert(index)
                continue
            }
            guard let item = itemsByPage[index] else { continue }
            let orientationMatches: Bool
            switch orientationRule {
            case .any: orientationMatches = true
            case .portrait: orientationMatches = !item.isLandscape
            case .landscape: orientationMatches = item.isLandscape
            }
            let paperMatches: Bool
            switch paperRule {
            case .any: paperMatches = true
            case .a4: paperMatches = item.paperClass == .a4
            case .letter: paperMatches = item.paperClass == .letter
            case .legal: paperMatches = item.paperClass == .legal
            case .square: paperMatches = item.paperClass == .square
            case .custom: paperMatches = item.paperClass == .custom
            }
            if orientationMatches && paperMatches {
                matches.insert(index)
            }
        }
        return matches
    }

    private var matchSummary: String {
        guard !matchingIndices.isEmpty else {
            return "No pages match these rules.".localizedUI
        }
        var visiblePages: [String] = []
        visiblePages.reserveCapacity(48)
        for index in 0..<pageCount
        where matchingIndices.contains(index) {
            visiblePages.append(String(index + 1))
            if visiblePages.count == 48 {
                break
            }
        }
        let visible = visiblePages.joined(separator: " · ")
        if matchingIndices.count > visiblePages.count {
            return visible + AppLocalization.format(
                " · +%lld more",
                matchingIndices.count - visiblePages.count
            )
        }
        return visible
    }

    private func groupedPageOrder(oddFirst: Bool) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(pageCount)
        let firstStart = oddFirst ? 0 : 1
        let secondStart = oddFirst ? 1 : 0
        result.append(
            contentsOf: stride(
                from: firstStart,
                to: pageCount,
                by: 2
            )
        )
        result.append(
            contentsOf: stride(
                from: secondStart,
                to: pageCount,
                by: 2
            )
        )
        return result
    }

    private var interleavedHalfOrder: [Int] {
        let split = (pageCount + 1) / 2
        var result: [Int] = []
        result.reserveCapacity(pageCount)
        for index in 0..<split {
            result.append(index)
            let secondIndex = split + index
            if secondIndex < pageCount {
                result.append(secondIndex)
            }
        }
        return result
    }

    private func startAssessment() {
        guard let requestedRevisionID = contentRevisionID else {
            ruleRevisionID = nil
            assessment = nil
            isLoading = false
            assessmentErrorMessage =
                "The page geometry could not be inspected. Try again."
                    .localizedUI
            assessmentErrorFeedback += 1
            return
        }
        let generation = UUID()
        analysisGeneration = generation
        analysisTask?.cancel()
        ruleRevisionID = requestedRevisionID
        isLoading = true
        assessment = nil
        assessmentErrorMessage = nil
        analysisTask = Task { @MainActor in
            let loaded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.pagePreparationAssessment(
                    recordID: recordID
                )
            }
            guard !Task.isCancelled,
                  analysisGeneration == generation,
                  contentRevisionID == requestedRevisionID
            else { return }
            assessment = loaded
            isLoading = false
            analysisTask = nil
            if loaded == nil {
                assessmentErrorMessage =
                    "Page size check failed. Retry before using orientation or paper rules."
                assessmentErrorFeedback += 1
            }
            scheduleMatchCalculation()
        }
    }

    private func scheduleMatchCalculation() {
        matchGeneration = UUID()
        matchTask?.cancel()
        let generation = matchGeneration
        let requestedPageCount = pageCount
        let requestedPages = assessment?.pages ?? []
        let requestedNumberRule = numberRule
        let requestedOrientationRule = orientationRule
        let requestedPaperRule = paperRule
        let requestedRevisionID = ruleRevisionID
        guard requestedRevisionID != nil,
              contentRevisionID == requestedRevisionID
        else {
            matchingIndices.removeAll()
            isCalculatingMatches = false
            return
        }
        isCalculatingMatches = true
        matchTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                Self.matchingIndices(
                    pageCount: requestedPageCount,
                    pages: requestedPages,
                    numberRule: requestedNumberRule,
                    orientationRule: requestedOrientationRule,
                    paperRule: requestedPaperRule
                )
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  matchGeneration == generation,
                  contentRevisionID == requestedRevisionID
            else { return }
            matchingIndices = matches
            isCalculatingMatches = false
            matchTask = nil
        }
    }

    private func interruptRuleAssessment() {
        analysisGeneration = UUID()
        matchGeneration = UUID()
        matchTask?.cancel()
        matchTask = nil
        isCalculatingMatches = false
        matchingIndices.removeAll()
        analysisTask?.cancel()
        analysisTask = nil
        isLoading = false
        assessment = nil
        ruleRevisionID = nil
        assessmentErrorMessage = nil
    }
}

private struct PagePreparationView: View {
    private enum ReviewMode: String, CaseIterable, Identifiable {
        case changes
        case all

        var id: String { rawValue }
        var title: String {
            switch self {
            case .changes: return "Needs changes"
            case .all: return "All pages"
            }
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

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
    @State private var applyGeneration = UUID()
    @State private var applyStopRequested = false
    @State private var selectionFeedback = 0
    @State private var didApplyInitialSelection = false
    @State private var initialSelectionRevisionID: UUID?

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
                            applyStopRequested
                                ? "Stopping"
                                : isBusy
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
                    .keyboardShortcut(.cancelAction)
                    .disabled(applyStopRequested)
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
        .onChange(of: currentContentRevisionID) { oldValue, newValue in
            guard oldValue != newValue,
                  applyTask == nil
            else { return }
            interruptPreparationWork()
            guard newValue != nil,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            startAssessment()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active,
               assessment?.revisionID != currentContentRevisionID,
               analysisTask == nil,
               applyTask == nil {
                startAssessment()
            } else if phase == .background {
                interruptPreparationWork()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptPreparationWork()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            guard scenePhase == .active,
                  analysisTask == nil,
                  applyTask == nil
            else { return }
            startAssessment()
        }
        .onDisappear {
            interruptPreparationWork()
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.medium) {
                    preparationSelectionButtons
                }
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    preparationSelectionButtons
                }
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

    @ViewBuilder
    private var preparationSelectionButtons: some View {
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

    private var reviewModePicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionEyebrow(text: "REVIEW")
            let picker = Picker("Review", selection: $reviewMode) {
                ForEach(ReviewMode.allCases) { mode in
                    Text(mode.title.localizedUI).tag(mode)
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
                picker
                    .pickerStyle(.segmented)
                    .frame(minWidth: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout ? nil : 220,
            maxWidth: .infinity,
            alignment: .leading
        )
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
            && !dynamicTypeSize.ppPrefersExpandedLayout
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
            .disabled(
                effectiveSelection.isEmpty
                    || isBusy
                    || model.isProcessing(recordID)
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

    private var currentContentRevisionID: UUID? {
        model.record(id: recordID)?.contentRevisionID
    }

    private func startAssessment() {
        guard let requestedRevisionID = currentContentRevisionID,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else {
            assessment = nil
            selectedPages.removeAll()
            return
        }
        if initialSelectionRevisionID == nil {
            initialSelectionRevisionID = requestedRevisionID
        }
        analysisTask?.cancel()
        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessment = nil
        selectedPages.removeAll()
        analysisTask = Task {
            let loaded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.pagePreparationAssessment(
                    recordID: recordID
                )
            }
            guard !Task.isCancelled,
                  generation == assessmentGeneration,
                  let loaded,
                  loaded.revisionID == requestedRevisionID,
                  currentContentRevisionID == requestedRevisionID
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
            if didApplyInitialSelection
                || requestedRevisionID
                    != initialSelectionRevisionID {
                selectedPages = suggestions
            } else {
                didApplyInitialSelection = true
                selectedPages = initialSelection.isEmpty
                    ? suggestions
                    : initialSelection.intersection(suggestions)
            }
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.18)
            ) {
                analysisTask = nil
            }
        }
    }

    private func applyPreparation() {
        guard let assessment,
              !model.isProcessing(recordID),
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
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
        let generation = UUID()
        applyGeneration = generation
        applyStopRequested = false
        applyTask = Task {
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.cropPages(
                    recordID: recordID,
                    insetsByPage: requests
                )
            }
            guard applyGeneration == generation else { return }
            let wasStopped =
                applyStopRequested || Task.isCancelled
            applyTask = nil
            applyStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    succeeded
                        ? "Page update finished before stopping · changes kept"
                        : "Page update stopped · working copy unchanged"
                ).localizedUI
                if succeeded {
                    startAssessment()
                }
                return
            }
            guard succeeded else { return }
            onComplete()
        }
    }

    private func stopWork() {
        if applyTask != nil {
            guard !applyStopRequested else { return }
            applyStopRequested = true
            applyTask?.cancel()
        } else {
            interruptPreparationWork()
        }
    }

    private func interruptPreparationWork() {
        assessmentGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        applyGeneration = UUID()
        applyStopRequested = false
        applyTask?.cancel()
        applyTask = nil
        assessment = nil
        selectedPages.removeAll()
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
        var title: String {
            switch self {
            case .none: return "None"
            case .light: return "Light"
            case .standard: return "Standard"
            case .tight: return "Tight"
            case .custom: return "Custom"
            }
        }

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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.paperPathSceneID) private var paperPathSceneID

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
    @State private var operationGeneration = UUID()
    @State private var operationStopRequested = false
    @State private var didCommitCrop = false
    @State private var previewGeneration = 0
    @State private var previewReloadToken = UUID()
    @State private var isLoadingPreview = true
    @State private var previewErrorMessage: String?

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
                    Button(
                        (
                            operationStopRequested
                                ? "Stopping"
                                : isApplying
                                    ? "Stop"
                                    : didCommitCrop
                                        ? "Done"
                                        : "Cancel"
                        ).localizedUI
                    ) {
                        if isApplying {
                            stopCropOperation()
                        } else if didCommitCrop {
                            onComplete()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(operationStopRequested)
                }
            }
            .task(id: cropPreviewRequestID) {
                previewGeneration += 1
                let generation = previewGeneration
                isLoadingPreview = true
                previewErrorMessage = nil
                preview = nil
                guard let url = model.url(for: recordID) else {
                    isLoadingPreview = false
                    previewErrorMessage =
                        "The working copy is unavailable.".localizedUI
                    return
                }
                let revision = model.refreshToken(for: recordID)
                let loaded =
                    await PDFEditorPreviewLoader.shared.preview(
                        url: url,
                        pageIndex: pageIndex,
                        revision: revision,
                        longEdge: 1_800
                    )
                guard !Task.isCancelled,
                      generation == previewGeneration,
                      model.refreshToken(for: recordID) == revision
                else {
                    return
                }
                guard let loaded else {
                    isLoadingPreview = false
                    previewErrorMessage =
                        "The page preview could not be loaded. Try again."
                            .localizedUI
                    return
                }
                preview = loaded.image
                pageAspectRatio = CGFloat(loaded.aspectRatio)
                isLoadingPreview = false
            }
            .onChange(of: preset) { _, value in
                guard value != .custom else { return }
                insets = value.insets
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, preview == nil {
                    previewReloadToken = UUID()
                } else if phase == .background {
                    interruptCropWork()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptCropWork()
            }
            .interactiveDismissDisabled(isApplying)
            .onDisappear {
                interruptCropWork()
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
                } else if let previewErrorMessage {
                    cropPreviewFailureState(previewErrorMessage)
                } else if isLoadingPreview {
                    VStack(spacing: PPSpacing.small) {
                        ProgressView()
                        Text("Loading page preview".localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                } else {
                    cropPreviewFailureState(
                        "The page preview stopped before it was ready. Try again."
                            .localizedUI
                    )
                }
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        }
    }

    private func cropPreviewFailureState(
        _ message: String
    ) -> some View {
        VStack(spacing: PPSpacing.small) {
            Image(systemName: "doc.questionmark")
                .font(.title2)
                .foregroundStyle(PPColor.amber)
            Text("Preview unavailable".localizedUI)
                .font(.headline)
                .foregroundStyle(PPColor.textPrimary)
            Text(message)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            Button {
                retryCropPreview()
            } label: {
                Label(
                    "Load Preview Again",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(
                PPQuietButtonStyle(tint: PPColor.cyan)
            )
            .accessibilityIdentifier(
                "retryPageCropPreview"
            )
        }
        .padding(PPSpacing.medium)
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
        ScrollView {
            VStack(spacing: PPSpacing.small) {
                OperationBoundaryNotice(
                    title: "Cropping only hides content",
                    detail: "Use Redact to remove information permanently.",
                    identifier: "pageCropBoundary",
                    symbol: "rectangle.dashed.badge.record"
                )
                cropPresetControl
                cropEdgeControls

                Button {
                    applyCrop()
                } label: {
                    Label(
                        isApplying ? "Applying Crop" : "Apply Crop",
                        systemImage: isApplying
                            ? "hourglass"
                            : "crop"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(
                    isApplying
                        || model.isProcessing(recordID)
                        || preview == nil
                        || !insets.isValid
                        || insets == .none
                )
            }
            .padding(.horizontal, PPSpacing.regular)
            .padding(.vertical, PPSpacing.small)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: cropControlsMaximumHeight)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    @ViewBuilder
    private var cropPresetControl: some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            Menu {
                ForEach(
                    CropPreset.allCases.filter { $0 != .custom }
                ) { option in
                    Button {
                        preset = option
                    } label: {
                        Label(
                            option.title.localizedUI,
                            systemImage: preset == option
                                ? "checkmark"
                                : "crop"
                        )
                    }
                }
            } label: {
                HStack {
                    Label(
                        "Crop preset",
                        systemImage: "slider.horizontal.3"
                    )
                    .font(.subheadline.weight(.semibold))
                    Spacer(minLength: PPSpacing.small)
                    Text(preset.title.localizedUI)
                        .foregroundStyle(PPColor.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Picker("Crop preset", selection: $preset) {
                ForEach(
                    CropPreset.allCases.filter { $0 != .custom }
                ) { option in
                    Text(option.title.localizedUI).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var cropEdgeControls: some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            VStack(spacing: PPSpacing.small) {
                edgeControl("Top", edge: .top)
                edgeControl("Bottom", edge: .bottom)
                edgeControl("Left", edge: .left)
                edgeControl("Right", edge: .right)
            }
        } else {
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
        }
    }

    private var cropControlsMaximumHeight: CGFloat {
        if verticalSizeClass == .compact {
            return 230
        }
        return dynamicTypeSize.ppPrefersExpandedLayout ? 360 : 280
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
        guard operationTask == nil,
              !didCommitCrop,
              !model.isProcessing(recordID),
              preview != nil,
              insets.isValid,
              insets != .none,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        isApplying = true
        operationStopRequested = false
        didCommitCrop = false
        let requestedInsets = insets
        let generation = UUID()
        operationGeneration = generation
        operationTask = Task { @MainActor in
            defer {
                if operationGeneration == generation {
                    isApplying = false
                    operationTask = nil
                    operationStopRequested = false
                }
            }
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.cropPage(
                    recordID: recordID,
                    index: pageIndex,
                    insets: requestedInsets
                )
            }
            guard operationGeneration == generation else {
                return
            }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    succeeded
                        ? "Page update finished before stopping · changes kept"
                        : "Page update stopped · working copy unchanged"
                ).localizedUI
                if succeeded {
                    didCommitCrop = true
                    preset = .none
                    insets = .none
                    previewReloadToken = UUID()
                }
                return
            }
            guard succeeded else { return }
            onComplete()
        }
    }

    private func retryCropPreview() {
        preview = nil
        previewErrorMessage = nil
        isLoadingPreview = true
        previewReloadToken = UUID()
    }

    private var cropPreviewRequestID: String {
        [
            recordID.uuidString,
            String(pageIndex),
            String(model.refreshToken(for: recordID)),
            previewReloadToken.uuidString
        ].joined(separator: "-")
    }

    private func interruptCropWork() {
        previewGeneration += 1
        preview = nil
        isLoadingPreview = false
        previewErrorMessage = nil
        didCommitCrop = false
        stopCropOperation(invalidateResult: true)
    }

    private func stopCropOperation(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            operationGeneration = UUID()
            operationStopRequested = false
        } else {
            guard operationTask != nil,
                  !operationStopRequested
            else { return }
            operationStopRequested = true
        }
        operationTask?.cancel()
        if invalidateResult {
            operationTask = nil
            isApplying = false
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let pageCount: Int
    let onSelect: (Set<Int>) -> Void

    @State private var usesPageNumbers = false
    @State private var pageNumbers = ""
    @State private var startPage = 1
    @State private var endPage: Int

    init(
        pageCount: Int,
        onSelect: @escaping (Set<Int>) -> Void
    ) {
        self.pageCount = max(1, pageCount)
        self.onSelect = onSelect
        _endPage = State(initialValue: min(max(1, pageCount), 10))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    selectionModePicker
                    if usesPageNumbers {
                        TextField("1, 3-5, 9", text: $pageNumbers)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Page numbers".localizedUI)
                            .accessibilityIdentifier("organizerPageNumbers")
                        if !pageNumbers.isEmpty, let selectionError {
                            Label(selectionError, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(PPColor.rose)
                        }
                    } else {
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
                    }
                } footer: {
                    Text(AppLocalization.format("%lld pages selected", selection.count))
                }
            }
            .navigationTitle("Select Page Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Select") {
                        guard !selection.isEmpty else { return }
                        onSelect(selection)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
                }
            }
            .onChange(of: pageNumbers) { _, value in
                if value.count > 2_048 { pageNumbers = String(value.prefix(2_048)) }
            }
        }
        .accessibilityAction(.escape) {
            dismiss()
        }
    }

    private var selection: Set<Int> {
        if !usesPageNumbers { return Set((startPage - 1)..<endPage) }
        return Set((try? PDFPageSelection.parse(pageNumbers, pageCount: pageCount)) ?? [])
    }

    @ViewBuilder
    private var selectionModePicker: some View {
        let picker = Picker(
            "Page selection".localizedUI,
            selection: $usesPageNumbers
        ) {
            Text("Range".localizedUI).tag(false)
            Text("Page numbers".localizedUI).tag(true)
        }
        if dynamicTypeSize.ppPrefersExpandedLayout {
            picker
                .pickerStyle(.menu)
                .frame(minHeight: 44)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var selectionError: String? {
        do {
            _ = try PDFPageSelection.parse(pageNumbers, pageCount: pageCount)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct PageCopyDestinationSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let sourceRecordID: UUID
    let selectedCount: Int
    let onSelect: (UUID) -> Void
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(destinations) { record in
                Button {
                    onSelect(record.id)
                } label: {
                    HStack(spacing: PPSpacing.medium) {
                        Image(systemName: record.profile.kind.symbol)
                            .foregroundStyle(PPColor.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.displayName)
                                .foregroundStyle(PPColor.textPrimary)
                                .lineLimit(
                                    dynamicTypeSize.ppPrefersExpandedLayout
                                        ? 3
                                        : 1
                                )
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                            Text(
                                "\(record.profile.pageCount) pages · append \(selectedCount)"
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                        }
                    }
                }
                .accessibilityHint(
                    AppLocalization.format(
                        "Copies %lld selected pages after this sheet closes",
                        selectedCount
                    )
                )
            }
            .overlay {
                if destinations.isEmpty {
                    ContentUnavailableView(
                        normalizedSearchText.isEmpty
                            ? "No destination PDF"
                            : "No matching PDF",
                        systemImage: normalizedSearchText.isEmpty
                            ? "doc.on.doc"
                            : "magnifyingglass",
                        description: Text(
                            normalizedSearchText.isEmpty
                                ? "Import or create another PDF first."
                                : "Try another document name or tag."
                        )
                    )
                }
            }
            .searchable(
                text: $searchText,
                prompt: "Search destination PDFs"
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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Copy Pages To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .accessibilityAction(.escape) {
            if !normalizedSearchText.isEmpty {
                searchText = ""
                dismissSearch()
            } else {
                dismiss()
            }
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private var destinations: [DocumentRecord] {
        model.documents.filter {
            $0.id != sourceRecordID
                && $0.isWorkingCopy
                && !$0.profile.isLocked
                && (
                    normalizedSearchText.isEmpty
                        || $0.displayName.localizedCaseInsensitiveContains(
                            normalizedSearchText
                        )
                        || $0.tags.contains {
                            $0.localizedCaseInsensitiveContains(
                                normalizedSearchText
                            )
                        }
                )
        }
    }
}
