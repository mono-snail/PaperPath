import SwiftUI
import UniformTypeIdentifiers

struct CombineDocumentsView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @AppStorage("privacy.hideLibraryPreviews")
    private var hideLibraryPreviews = false

    let onCreated: (UUID) -> Void

    @State private var selectedIDs: [UUID] = []
    @State private var isLibraryExpanded = true
    @State private var draggedID: UUID?
    @State private var mergeRowFrames: [UUID: CGRect] = [:]
    @State private var outputName = ""
    @State private var sourceQuery = ""
    @FocusState private var sourceSearchFocused: Bool
    @State private var isAddingFiles = false
    @State private var importTask: Task<Void, Never>?
    @State private var operationTask: Task<Void, Never>?
    @State private var importGeneration = UUID()
    @State private var operationGeneration = UUID()
    @State private var createdID: UUID?
    @State private var createdSourceCount = 0
    @State private var isStopRequested = false

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    Group {
                        if let createdRecord {
                            resultContent(createdRecord)
                        } else {
                            selectionContent
                        }
                    }
                    .frame(maxWidth: 1_080)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 94)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Merge PDFs".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if createdID == nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isLibraryExpanded = true
                            sourceSearchFocused = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .keyboardShortcut("f", modifiers: .command)
                        .accessibilityLabel("Search PDFs to merge".localizedUI)
                        .disabled(hasActiveTask)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            hasActiveTask
                                ? isStopRequested
                                    ? "Stopping"
                                    : "Stop"
                                : createdID == nil
                                    ? "Cancel"
                                    : "Done"
                        ).localizedUI
                    ) {
                        if hasActiveTask {
                            stopActiveTask()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(hasActiveTask && isStopRequested)
                    .accessibilityHint(
                        hasActiveTask
                            ? "Stops safely. Finished private copies remain in the Library."
                                .localizedUI
                            : ""
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionBar
            }
        }
        .fileImporter(
            isPresented: $isAddingFiles,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            let urls: [URL]
            switch result {
            case .success(let selectedURLs):
                var seenPaths = Set<String>()
                urls = selectedURLs.filter {
                    seenPaths.insert(
                        $0.standardizedFileURL.path
                    ).inserted
                }
            case .failure(let error):
                if !Self.isFileImportCancellation(error) {
                    model.present(error, in: paperPathSceneID)
                }
                return
            }
            guard !urls.isEmpty else { return }
            cancelImport()
            let generation = UUID()
            importGeneration = generation
            isStopRequested = false
            importTask = Task { @MainActor in
                let imported = await model.withFeedbackTarget(paperPathSceneID) {
                    await model.importPDFs(
                        from: urls,
                        progressID: generation
                    )
                }
                guard !Task.isCancelled,
                      importGeneration == generation
                else { return }
                var skippedForCapacity = 0
                for record in imported
                where !record.profile.isLocked
                    && !selectedIDs.contains(record.id) {
                    guard canAdd(record) else {
                        skippedForCapacity += 1
                        continue
                    }
                    selectedIDs.append(record.id)
                }
                if skippedForCapacity > 0 {
                    model.present(
                        PaperPathError.insufficientSelection(
                            "Merge limit reached. Extra PDFs remain in the Library."
                        ),
                        in: paperPathSceneID
                    )
                }
                importTask = nil
            }
        }
        .interactiveDismissDisabled(hasActiveTask)
        .accessibilityAction(.escape) {
            if hasActiveTask {
                stopActiveTask()
            } else {
                dismiss()
            }
        }
        .onDisappear {
            cancelImport()
            cancelOperation(invalidateResult: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptProtectedMerge()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtectedMerge()
        }
        .onChange(of: outputName) { _, value in
            if value.count > 80 {
                outputName = String(value.prefix(80))
            }
        }
        .onChange(of: sourceQuery) { _, value in
            if value.count > 256 { sourceQuery = String(value.prefix(256)) }
        }
        .onChange(of: mergeEligibleRecordIDs) { _, _ in
            reconcileSelection()
        }
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: selectedIDs.count) { oldCount, newCount in
            if newCount < 2 { isLibraryExpanded = true }
            else if oldCount < 2 { isLibraryExpanded = false }
        }
        .sensoryFeedback(.selection, trigger: selectedIDs.count)
        .sensoryFeedback(.success, trigger: createdID)
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: PPSpacing.large) {
            taskHeader
            if horizontalSizeClass == .regular,
               !dynamicTypeSize.ppPrefersExpandedLayout {
                HStack(alignment: .top, spacing: PPSpacing.xLarge) {
                    VStack(alignment: .leading, spacing: PPSpacing.large) {
                        if !selectedIDs.isEmpty {
                            selectedOrder
                            nameField
                        } else { compactMergeHint }
                        sourceActions
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    librarySources
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                if !selectedIDs.isEmpty {
                    selectedOrder
                    nameField
                }
                sourceActions
                DisclosureGroup(isExpanded: $isLibraryExpanded) {
                    librarySources.padding(.top, PPSpacing.small)
                } label: {
                    Text("From your library".localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                }
                .accessibilityIdentifier("mergeLibraryDisclosure")
            }
            Label("Originals stay unchanged".localizedUI, systemImage: "doc")
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
        }
    }

    private var librarySources: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            TextField("Search PDFs to merge".localizedUI, text: $sourceQuery)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($sourceSearchFocused)
                .disabled(hasActiveTask)
            availableDocuments
        }
    }

    private var taskHeader: some View {
        HStack {
            Text(AppLocalization.format("%lld PDFs · %lld pages", selectedIDs.count, selectedPageCount))
                .font(.subheadline)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: selectedByteCount, countStyle: .file))
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(PPColor.textSecondary)
    }

    private var compactMergeHint: some View {
        HStack(spacing: PPSpacing.small) {
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(PPColor.mint)
            Text("Choose at least 2 PDFs to build the merge order.")
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var sourceActions: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "ADD PDFS")

            Button {
                isAddingFiles = true
            } label: {
                Label("Add from Files", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.accent))
            .disabled(
                hasActiveTask
                    || !canAddMoreSources
            )
            .accessibilityHint(
                (
                    selectionLimitMessage
                        ?? (
                            hasActiveTask
                                ? "Wait for the current operation to finish."
                                : "Choose one or more PDFs from Files."
                        )
                ).localizedUI
            )

            if let selectionLimitMessage {
                Label(
                    selectionLimitMessage.localizedUI,
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
            }
        }
    }

    private var selectedOrder: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            HStack {
                Text("Selected PDFs".localizedUI).font(.headline)
                Spacer()
                Text("\(selectedIDs.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.mint)
                Menu {
                    Button {
                        selectedIDs = selectedRecords.sorted {
                            let comparison = $0.displayName
                                .localizedStandardCompare(
                                    $1.displayName
                                )
                            if comparison != .orderedSame {
                                return comparison == .orderedAscending
                            }
                            return $0.id.uuidString
                                < $1.id.uuidString
                        }.map(\.id)
                    } label: {
                        Label("Sort merge order by name".localizedUI, systemImage: "textformat.abc")
                    }
                    Button {
                        selectedIDs.reverse()
                    } label: {
                        Label("Reverse merge order".localizedUI, systemImage: "arrow.up.arrow.down")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 44, height: 44)
                }
                .disabled(hasActiveTask || selectedIDs.count < 2)
                .accessibilityLabel("Arrange merge order".localizedUI)
                .help("Arrange merge order".localizedUI)
                Button {
                    selectedIDs.removeAll(keepingCapacity: false)
                } label: {
                    Image(systemName: "xmark.circle")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.textSecondary)
                .disabled(hasActiveTask)
                .accessibilityLabel("Clear merge order".localizedUI)
            }

            LazyVStack(spacing: 0) {
                ForEach(Array(selectedRecords.enumerated()), id: \.element.id) {
                    index,
                    record in
                    selectedRow(record, at: index)

                    if index < selectedRecords.count - 1 {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.58))
                            .frame(height: 0.6)
                            .padding(.leading, 64)
                    }
                }
            }
            .coordinateSpace(name: "mergeOrder")
            .onPreferenceChange(MergeOrderFramePreference.self) { mergeRowFrames = $0 }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
        }
    }

    private func selectedRow(
        _ record: DocumentRecord,
        at index: Int
    ) -> some View {
        let expandsRow = dynamicTypeSize.ppPrefersExpandedLayout
        let layout = expandsRow
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                )
            )
            : AnyLayout(
                HStackLayout(spacing: PPSpacing.small)
            )

        return layout {
            HStack(spacing: PPSpacing.small) {
                Text("\(index + 1)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(width: 22, height: 28)
                    .contextMenu {
                        Button("Move to Beginning".localizedUI) { move(from: index, to: 0) }
                            .disabled(index == 0 || hasActiveTask)
                        Button("Move to End".localizedUI) { move(from: index, to: selectedIDs.count - 1) }
                            .disabled(index == selectedIDs.count - 1 || hasActiveTask)
                    }

                sourcePreview(record)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? nil
                                : 2
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    Text(record.subtitle)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .monospacedDigit()
                }

                if !expandsRow {
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 0) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .named("mergeOrder"))
                            .onChanged { value in
                                guard !hasActiveTask else { return }
                                draggedID = record.id
                            }
                            .onEnded { value in
                                reorder(record.id, at: value.location)
                                draggedID = nil
                            }
                    )
                    .allowsHitTesting(!hasActiveTask)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Drag to reorder".localizedUI)
                    .accessibilityHint("Or use Move earlier and Move later.".localizedUI)
                    .accessibilityIdentifier("mergeDrag-\(record.id.uuidString)")
                if horizontalSizeClass == .regular || expandsRow {
                orderButton(
                    symbol: "arrow.up",
                    label: "Move earlier",
                    disabled: index == 0
                ) {
                    move(from: index, to: index - 1)
                }
                .accessibilityValue(record.displayName)
                orderButton(
                    symbol: "arrow.down",
                    label: "Move later",
                    disabled: index == selectedIDs.count - 1
                ) {
                    move(from: index, to: index + 1)
                }
                .accessibilityValue(record.displayName)
                }
                orderButton(
                    symbol: "xmark",
                    label: "Remove",
                    tint: PPColor.amber
                ) {
                    selectedIDs.remove(at: index)
                }
                .accessibilityValue(record.displayName)
            }
            .frame(
                maxWidth: expandsRow
                    ? .infinity
                    : nil,
                alignment: .trailing
            )
        }
        .padding(.vertical, PPSpacing.small)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(record.displayName)
        .accessibilityAction(named: Text("Move earlier".localizedUI)) { move(from: index, to: index - 1) }
        .accessibilityAction(named: Text("Move later".localizedUI)) { move(from: index, to: index + 1) }
        .accessibilityIdentifier(
            "mergeSelectedDocument-\(record.id.uuidString)"
        )
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MergeOrderFramePreference.self,
                    value: [record.id: geometry.frame(in: .named("mergeOrder"))]
                )
            }
        }
        .background(PPColor.accent.opacity(draggedID == record.id ? 0.08 : 0))
    }

    private func reorder(_ sourceID: UUID, at location: CGPoint) {
        guard !hasActiveTask,
              let source = selectedIDs.firstIndex(of: sourceID),
              let destination = selectedIDs.firstIndex(where: {
                  $0 != sourceID && mergeRowFrames[$0]?.contains(location) == true
              })
        else { return }
        move(from: source, to: destination)
    }

    private func orderButton(
        symbol: String,
        label: String,
        tint: Color = PPColor.textSecondary,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || hasActiveTask)
        .opacity(disabled ? 0.28 : 1)
        .accessibilityLabel(label.localizedUI)
        .help(label.localizedUI)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Text("New copy name".localizedUI).font(.subheadline.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    mergeNameTextField
                    mergeNamePasteButton
                }
                VStack(
                    alignment: .trailing,
                    spacing: PPSpacing.xSmall
                ) {
                    mergeNameTextField
                    mergeNamePasteButton
                }
            }
        }
        .disabled(hasActiveTask)
    }

    private var mergeNameTextField: some View {
        TextField("Combined document".localizedUI, text: $outputName)
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .font(.body)
            .padding(PPSpacing.medium)
            .background(PPColor.surfaceMuted)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PPRadius.control,
                    style: .continuous
                )
            )
            .accessibilityIdentifier("mergeOutputName")
    }

    private var mergeNamePasteButton: some View {
        PasteButton(payloadType: String.self) { values in
            guard let value = values.first else { return }
            outputName = String(
                value
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .prefix(80)
            )
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint(
            "Pastes a name without changing the source PDFs."
                .localizedUI
        )
    }

    private var availableDocuments: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            HStack {
                SectionEyebrow(text: "PAPERPATH PDFS")
                Spacer()
                Text("\(availableRecords.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textSecondary)
                if addableRecords.count > 1 {
                    Button {
                        addAllAvailableRecords()
                    } label: {
                        Label(
                            (normalizedSourceQuery.isEmpty ? "Add All" : "Add matching PDFs").localizedUI,
                            systemImage: "plus.circle"
                        )
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.accent)
                    .disabled(hasActiveTask)
                    .accessibilityHint(
                        "Adds matching unlocked PDFs within the merge limits."
                            .localizedUI
                    )
                }
            }

            if availableRecords.isEmpty {
                VStack(spacing: PPSpacing.medium) {
                    Image(systemName: "doc.badge.plus")
                        .font(.title2)
                        .foregroundStyle(PPColor.accent)
                    Text(
                        !normalizedSourceQuery.isEmpty
                            ? "No matching PDFs".localizedUI
                            : selectedIDs.isEmpty
                            ? "Add PDFs from Files".localizedUI
                            : "All available PDFs are selected".localizedUI
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    if !normalizedSourceQuery.isEmpty {
                        Button("Clear search".localizedUI) {
                            sourceQuery = ""
                        }
                        .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, PPSpacing.large)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(availableRecords.enumerated()),
                        id: \.element.id
                    ) { index, record in
                        availableRow(record)

                        if index < availableRecords.count - 1 {
                            Rectangle()
                                .fill(PPColor.border.opacity(0.58))
                                .frame(height: 0.6)
                                .padding(.leading, 64)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.62))
                        .frame(height: 0.6)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.62))
                        .frame(height: 0.6)
                }
            }
        }
    }

    private func availableRow(_ record: DocumentRecord) -> some View {
        let supported = !record.profile.isLocked
        let hasCapacity = canAdd(record)
        let selectable = supported && hasCapacity

        return Button {
            selectedIDs.append(record.id)
        } label: {
            HStack(spacing: PPSpacing.medium) {
                Image(
                    systemName: !supported
                        ? "lock.circle"
                        : hasCapacity
                            ? "plus.circle"
                            : "exclamationmark.circle"
                )
                    .font(.title3)
                    .foregroundStyle(
                        selectable
                            ? PPColor.accent
                            : PPColor.textSecondary
                    )
                    .frame(width: 28)

                sourcePreview(record)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayName)
                        .font(.body.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? nil
                                : 1
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        !supported
                            ? "Locked PDF".localizedUI
                            : hasCapacity
                                ? record.subtitle
                                : "Merge limit reached".localizedUI
                    )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .monospacedDigit()
                }

                Spacer()
            }
            .padding(.vertical, PPSpacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable || hasActiveTask)
        .opacity(selectable ? 1 : 0.48)
        .accessibilityLabel(
            AppLocalization.format("Add %@", record.displayName)
        )
        .accessibilityHint(
            hasActiveTask
                ? "Wait for the current operation to finish.".localizedUI
                : selectable
                    ? ""
                    : (
                    supported
                        ? "Remove another PDF before adding this one."
                        : "Unlock this PDF before merging it."
                    ).localizedUI
        )
        .accessibilityIdentifier(
            "mergeAvailableDocument-\(record.id.uuidString)"
        )
    }

    @ViewBuilder
    private func sourcePreview(_ record: DocumentRecord) -> some View {
        if !hideLibraryPreviews,
           let url = model.url(for: record.id) {
            PDFPageThumbnailView(
                url: url,
                pageIndex: 0,
                refreshToken: model.refreshToken(for: record.id),
                width: 38
            )
        } else {
            ToolSymbolPlate(
                symbol: record.profile.kind.symbol,
                tint: PPColor.cyan,
                size: 38
            )
        }
    }

    private func resultContent(
        _ record: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.large) {
            WorkflowCommandHeader(
                eyebrow: "MERGE RESULT",
                title: "Merged PDF ready",
                detail: "The source PDFs remain unchanged.",
                symbol: "checkmark.circle.fill",
                tint: PPColor.mint,
                metrics: [
                    WorkflowMetric(
                        value: "\(createdSourceCount)",
                        label: "Sources",
                        symbol: "square.stack.3d.up",
                        tint: PPColor.mint
                    ),
                    WorkflowMetric(
                        value: "\(record.profile.pageCount)",
                        label: "Pages",
                        symbol: "doc.on.doc",
                        tint: PPColor.accent
                    ),
                    WorkflowMetric(
                        value: record.profile.formattedSize,
                        label: "Output",
                        symbol: "internaldrive",
                        tint: PPColor.cyan
                    )
                ]
            )

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
            layout {
                HStack(spacing: PPSpacing.medium) {
                    sourcePreview(record)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(PPColor.mint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayName)
                        .font(.body.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? nil
                                : 2
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    Text(record.subtitle)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .monospacedDigit()
                }

                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, PPSpacing.medium)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
            .accessibilityElement(children: .combine)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: PPSpacing.small) {
            if let activeTaskLabel {
                if importTask != nil,
                   let progress = model.foregroundImportProgress(
                       for: importGeneration
                   ) {
                    LocalOperationProgressView(progress: progress)
                        .accessibilityIdentifier(
                            "mergePDFImportProgress"
                        )
                } else {
                    HStack(spacing: PPSpacing.medium) {
                        ProgressView()
                        Text(activeTaskLabel.localizedUI)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textSecondary)
                        Spacer()
                    }
                    .frame(minHeight: 52)
                }
                Button {
                    stopActiveTask()
                } label: {
                    Label(
                        isStopRequested ? "Stopping" : "Stop",
                        systemImage: isStopRequested
                            ? "hourglass"
                            : "stop.fill"
                    )
                        .frame(minHeight: 44)
                }
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.amber)
                )
                .disabled(isStopRequested)
                .accessibilityHint(
                    "Finished private copies remain in the Library."
                        .localizedUI
                )
            } else if let createdRecord {
                Button {
                    onCreated(createdRecord.id)
                } label: {
                    Label("Open Result", systemImage: "doc.text.magnifyingglass")
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("mergeOpenResult")
            } else {
                Button {
                    let generation = UUID()
                    let sourceIDs = selectedIDs
                    let requestedName = outputName
                    createdSourceCount = sourceIDs.count
                    operationGeneration = generation
                    isStopRequested = false
                    operationTask = Task { @MainActor in
                        defer {
                            if operationGeneration == generation {
                                operationTask = nil
                                isStopRequested = false
                            }
                        }
                        let created = await model.withFeedbackTarget(
                            paperPathSceneID
                        ) {
                            await model.combineDocuments(
                                recordIDs: sourceIDs,
                                name: requestedName
                            )
                        }
                        guard operationGeneration == generation else {
                            return
                        }
                        if Task.isCancelled {
                            createdID = created?.id
                            return
                        }
                        createdID = created?.id
                    }
                } label: {
                    Label(
                        selectedIDs.count < 2
                            ? "Choose at least 2 PDFs".localizedUI
                            : AppLocalization.format(
                                "Merge %lld PDFs",
                                selectedIDs.count
                            ),
                        systemImage: "square.stack.3d.up.fill"
                    )
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectedIDs.count < 2
                        || selectedIDs.count
                            > PDFCompositionService
                                .maximumSourceDocumentCount
                        || selectedPageCount
                            > PDFCompositionService.maximumPageCount
                        || hasActiveTask
                )
                .accessibilityHint(
                    (
                        mergeDisabledReason
                            ?? "Creates a separate private working copy."
                    ).localizedUI
                )
                .accessibilityIdentifier("mergeCreateAction")
            }
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

    private var selectedRecords: [DocumentRecord] {
        selectedIDs.compactMap { model.record(id: $0) }
    }

    private var mergeEligibleRecordIDs: Set<UUID> {
        Set(
            model.workingDocuments.lazy
                .filter {
                    $0.workflowStatus != .archived
                        && !$0.profile.isLocked
                }
                .map(\.id)
        )
    }

    private var selectedPageCount: Int {
        selectedRecords.reduce(0) { total, record in
            let (next, overflow) = total.addingReportingOverflow(
                record.profile.pageCount
            )
            return overflow ? .max : next
        }
    }

    private var selectedByteCount: Int64 {
        selectedRecords.reduce(0) { total, record in
            let (next, overflow) = total.addingReportingOverflow(
                max(0, record.profile.byteCount)
            )
            return overflow ? .max : next
        }
    }

    private var canAddMoreSources: Bool {
        selectedIDs.count
            < PDFCompositionService.maximumSourceDocumentCount
            && selectedPageCount
                < PDFCompositionService.maximumPageCount
    }

    private var selectionLimitMessage: String? {
        if selectedIDs.count
            >= PDFCompositionService.maximumSourceDocumentCount {
            return "64-PDF merge limit reached"
        }
        if selectedPageCount
            >= PDFCompositionService.maximumPageCount {
            return "100,000-page merge limit reached"
        }
        return nil
    }

    private var mergeDisabledReason: String? {
        if selectedIDs.count < 2 {
            return "Choose at least 2 PDFs."
        }
        if selectedIDs.count
            > PDFCompositionService.maximumSourceDocumentCount {
            return "Choose no more than 64 PDFs."
        }
        if selectedPageCount
            > PDFCompositionService.maximumPageCount {
            return "Choose no more than 100,000 pages."
        }
        if hasActiveTask {
            return "Wait for the current operation to finish."
        }
        return nil
    }

    private var availableRecords: [DocumentRecord] {
        model.workingDocuments.filter {
            $0.workflowStatus != .archived
                && !selectedIDs.contains($0.id)
                && (normalizedSourceQuery.isEmpty
                    || $0.displayName.localizedStandardContains(normalizedSourceQuery)
                    || $0.tags.contains { $0.localizedStandardContains(normalizedSourceQuery) })
        }
    }

    private var normalizedSourceQuery: String {
        sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var addableRecords: [DocumentRecord] {
        availableRecords.filter {
            !$0.profile.isLocked && canAdd($0)
        }
    }

    private var createdRecord: DocumentRecord? {
        createdID.flatMap { model.record(id: $0) }
    }

    private var hasActiveTask: Bool {
        importTask != nil || operationTask != nil
    }

    private var activeTaskLabel: String? {
        if importTask != nil {
            return "Importing PDFs on this device"
        }
        if operationTask != nil {
            return "Merging PDFs on this device"
        }
        return nil
    }

    private func move(from source: Int, to destination: Int) {
        guard !hasActiveTask, selectedIDs.indices.contains(source),
              selectedIDs.indices.contains(destination),
              source != destination
        else { return }
        let id = selectedIDs.remove(at: source)
        selectedIDs.insert(id, at: destination)
    }

    private func reconcileSelection() {
        guard createdID == nil else { return }
        let reconciled = selectedIDs.filter(
            mergeEligibleRecordIDs.contains
        )
        guard reconciled != selectedIDs else { return }
        let removedCount = selectedIDs.count - reconciled.count
        selectedIDs = reconciled
        model[noticeFor: paperPathSceneID] = AppLocalization.format(
            "%lld unavailable PDF%@ removed from merge order",
            removedCount,
            removedCount == 1 ? "" : "s"
        )
    }

    private func canAdd(_ record: DocumentRecord) -> Bool {
        guard selectedIDs.count
                < PDFCompositionService.maximumSourceDocumentCount
        else { return false }
        let (nextPageCount, overflow) = selectedPageCount
            .addingReportingOverflow(record.profile.pageCount)
        return !overflow
            && nextPageCount
                <= PDFCompositionService.maximumPageCount
    }

    private func addAllAvailableRecords() {
        guard !hasActiveTask else { return }
        for record in availableRecords
        where !record.profile.isLocked && canAdd(record) {
            selectedIDs.append(record.id)
        }
    }

    private func stopActiveTask() {
        guard !isStopRequested else { return }
        isStopRequested = true
        if operationTask != nil {
            cancelOperation()
        } else {
            cancelImport(showsNotice: true)
        }
    }

    private func cancelImport(
        showsNotice: Bool = false
    ) {
        let cancelledProgressID = importGeneration
        importGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        isStopRequested = false
        model.clearForegroundImportProgress(
            cancelledProgressID
        )
        if showsNotice {
            model[noticeFor: paperPathSceneID] =
                "PDF import stopped · finished copies stay in the Library"
                    .localizedUI
        }
    }

    private func cancelOperation(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            operationGeneration = UUID()
        }
        operationTask?.cancel()
        if invalidateResult {
            operationTask = nil
            isStopRequested = false
        }
    }

    private func interruptProtectedMerge() {
        cancelImport()
        cancelOperation(invalidateResult: true)
        selectedIDs.removeAll(keepingCapacity: false)
        outputName = ""
        createdID = nil
        createdSourceCount = 0
        isAddingFiles = false
        dismiss()
    }

    private nonisolated static func isFileImportCancellation(
        _ error: Error
    ) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSUserCancelledError
    }
}

private struct MergeOrderFramePreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
