import QuickLook
import SwiftUI
import UniformTypeIdentifiers

private struct CompressionTaskResult: Identifiable {
    let sourceID: UUID
    let sourceName: String
    let sourceByteCount: Int64
    let outputID: UUID?
    let outputName: String?
    let outputByteCount: Int64?
    let issue: PDFBatchDeliveryIssue?

    var id: UUID { sourceID }
}

private struct CompressionQualityPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: PDFCompressionQuality

    var body: some View {
        let picker = Picker("Output quality", selection: $selection) {
            ForEach(PDFCompressionQuality.allCases) { option in
                Text(option.title.localizedUI)
                    .tag(option)
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

private struct CompressionModePicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: PDFCompressionMode

    var body: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            let modes: [PDFCompressionMode] = selection == .imageCopy
                ? [.preserveContent, .optimizedImages, .imageCopy]
                : [.preserveContent, .optimizedImages]
            let picker = Picker("Compression method".localizedUI, selection: $selection) {
                ForEach(modes) { mode in
                    Text((mode == .imageCopy ? "Image pages" : mode.title).localizedUI).tag(mode)
                }
            }
            .accessibilityIdentifier("compressionMethodPicker")
            if dynamicTypeSize.ppPrefersExpandedLayout {
                picker.pickerStyle(.menu)
            } else {
                picker.pickerStyle(.segmented)
            }
            DisclosureGroup("More options".localizedUI) {
                Button("Image pages (lossy)".localizedUI) { selection = .imageCopy }
                    .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
            }
            .font(.caption)
        }
    }

}

struct BatchCompressionView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("privacy.hideLibraryPreviews")
    private var hideLibraryPreviews = false

    let onOpen: (DocumentRoute) -> Void

    @State private var selectedIDs: [UUID] = []
    @State private var quality = PDFCompressionQuality.readable
    @State private var compressionMode = PDFCompressionMode.preserveContent
    @State private var isAddingFiles = false
    @State private var importTask: Task<Void, Never>?
    @State private var operationTask: Task<Void, Never>?
    @State private var importGeneration = UUID()
    @State private var operationGeneration = UUID()
    @State private var operationStopRequested = false
    @State private var currentRecordID: UUID?
    @State private var completedCount = 0
    @State private var activeCompressionCount = 0
    @State private var results: [CompressionTaskResult] = []
    @State private var hasCompletedBatch = false
    @State private var importErrorMessage: String?
    @State private var failureFeedback = 0

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    Group {
                        if hasCompletedBatch {
                            resultsContent
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
            .navigationTitle("Compress PDF".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            !hasActiveTask
                                ? (hasCompletedBatch ? "Done" : "Cancel")
                                : operationStopRequested
                                    ? "Stopping"
                                    : "Stop"
                        ).localizedUI
                    ) {
                        if operationTask != nil {
                            interruptBatchCompression()
                        } else if importTask != nil {
                            cancelImport(showsNotice: true)
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(operationStopRequested)
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
                    presentImportError(
                        "The selected PDFs could not be imported. Try again."
                            .localizedUI
                    )
                }
                return
            }
            guard !urls.isEmpty else { return }
            cancelImport()
            importErrorMessage = nil
            let generation = UUID()
            importGeneration = generation
            importTask = Task { @MainActor in
                let imported = await model.withFeedbackTarget(
                    paperPathSceneID
                ) {
                    await model.importPDFs(
                        from: urls,
                        progressID: generation
                    )
                }
                guard !Task.isCancelled,
                      importGeneration == generation
                else { return }
                let previousSelectionCount = selectedIDs.count
                for record in imported
                where PDFQuickTask.compressPDF.supports(record)
                    && !selectedIDs.contains(record.id) {
                    selectedIDs.append(record.id)
                }
                if selectedIDs.count == previousSelectionCount {
                    presentImportError(
                        "No supported unlocked PDFs were added."
                            .localizedUI
                    )
                } else {
                    importErrorMessage = nil
                }
                importTask = nil
            }
        }
        .onDisappear {
            cancelImport()
            interruptBatchCompression(invalidateResult: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            cancelImport()
            interruptBatchCompression(invalidateResult: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            cancelImport()
            interruptBatchCompression(invalidateResult: true)
        }
        .interactiveDismissDisabled(hasActiveTask)
        .sensoryFeedback(.selection, trigger: selectedIDs.count)
        .sensoryFeedback(.success, trigger: hasCompletedBatch)
        .sensoryFeedback(.error, trigger: failureFeedback)
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: PPSpacing.large) {
            taskHeader
            if let importErrorMessage {
                batchImportErrorBanner(importErrorMessage)
            }
            if horizontalSizeClass == .regular,
               !dynamicTypeSize.ppPrefersExpandedLayout {
                HStack(alignment: .top, spacing: PPSpacing.large) {
                    qualityControl
                        .frame(maxWidth: 320, alignment: .top)
                    sourcePicker
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                qualityControl
                sourcePicker
            }
        }
    }

    private var taskHeader: some View {
        HStack {
            Text(AppLocalization.format("%lld selected", selectedIDs.count))
            Spacer()
            Text(formattedSelectedSize).monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(PPColor.textSecondary)
    }

    private var qualityControl: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            CompressionModePicker(selection: $compressionMode)
                .disabled(operationTask != nil)
            if compressionMode == .imageCopy {
                Text("Compression quality".localizedUI).font(.subheadline.weight(.semibold))
                CompressionQualityPicker(selection: $quality)
                    .disabled(operationTask != nil)
                Text(quality.detail.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if compressionMode == .imageCopy {
                OperationBoundaryNotice(
                    title: compressionMode.title,
                    detail: compressionMode.detail,
                    identifier: "batchCompressionOutputBoundary"
                )
            } else {
                Text(compressionMode.detail.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .accessibilityIdentifier("batchCompressionOutputBoundary")
            }
        }
    }

    private func batchImportErrorBanner(
        _ message: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                Label(
                    message,
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.rose)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: PPSpacing.small)
                Button("Choose Again".localizedUI) {
                    importErrorMessage = nil
                    isAddingFiles = true
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.rose))
            }
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                Label(
                    message,
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.rose)
                Button("Choose Again".localizedUI) {
                    importErrorMessage = nil
                    isAddingFiles = true
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.rose))
            }
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, PPSpacing.small)
        .background(PPColor.rose.opacity(0.08))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PPColor.rose)
                .frame(width: 2)
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    sourceHeading
                    Spacer()
                    addFilesButton
                }
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    sourceHeading
                    addFilesButton
                }
            }

            if availableRecords.isEmpty {
                Button {
                    isAddingFiles = true
                } label: {
                    Label(
                        "Choose PDFs from Files",
                        systemImage: "folder.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.accent))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(availableRecords.enumerated()),
                        id: \.element.id
                    ) { index, record in
                        sourceRow(record)

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

    private var sourceHeading: some View {
        HStack(spacing: PPSpacing.small) {
            SectionEyebrow(text: "PAPERPATH PDFS")
            if !selectedIDs.isEmpty {
                Text("\(selectedIDs.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.accent)
            }
        }
    }

    private var addFilesButton: some View {
        Button {
            isAddingFiles = true
        } label: {
            Label("Add from Files", systemImage: "folder.badge.plus")
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.accent))
        .disabled(hasActiveTask)
    }

    private func sourceRow(_ record: DocumentRecord) -> some View {
        let supported = PDFQuickTask.compressPDF.supports(record)
        let selected = selectedIDs.contains(record.id)

        return Button {
            toggle(record.id)
        } label: {
            HStack(spacing: PPSpacing.medium) {
                selectionMarker(
                    selected: selected,
                    supported: supported
                )

                sourcePreview(record)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayName)
                        .font(.body.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                        )
                    Text(
                        supported
                            ? record.subtitle
                            : "Locked PDF".localizedUI
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .monospacedDigit()
                }

                Spacer(minLength: PPSpacing.small)

                if currentRecordID == record.id,
                   let progress = model.progress(for: record.id) {
                    Text("\(progress.percentCompleted)%")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PPColor.accent)
                }
            }
            .padding(.vertical, PPSpacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!supported || operationTask != nil)
        .opacity(supported ? 1 : 0.48)
        .accessibilityLabel(
            AppLocalization.format(
                "%@, %@",
                record.displayName,
                selected
                    ? "selected".localizedUI
                    : "not selected".localizedUI
            )
        )
        .accessibilityHint(
            supported
                ? (
                    selected
                        ? "Removes this PDF from the compression batch."
                        : "Adds this PDF to the compression batch."
                ).localizedUI
                : "Unlock this PDF before compressing it."
                    .localizedUI
        )
        .accessibilityIdentifier(
            "batchCompressionDocument-\(record.id.uuidString)"
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

    private func selectionMarker(
        selected: Bool,
        supported: Bool
    ) -> some View {
        Image(
            systemName: supported
                ? (selected ? "checkmark.circle.fill" : "circle")
                : "lock.circle"
        )
        .font(.title3)
        .foregroundStyle(
            selected ? PPColor.accent : PPColor.textSecondary
        )
        .frame(width: 28, height: 28)
    }

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: PPSpacing.section) {
            resultHeader
            if compressionMode == .preserveContent,
               results.contains(where: isAlreadyOptimized) {
                Button("Try high-quality compression (lossy)".localizedUI) {
                    let retryIDs = results.filter(isAlreadyOptimized).map(\.sourceID)
                    quality = .readable
                    compressionMode = .optimizedImages
                    startCompression(recordIDs: retryIDs)
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.accent))
                .accessibilityIdentifier("batchCompressionTryLossyAction")
            }


            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) {
                    index,
                    result in
                    resultRow(result)

                    if index < results.count - 1 {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.58))
                            .frame(height: 0.6)
                            .padding(.leading, 48)
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

    private var resultHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "COMPRESSION RESULT",
            title: batchResultTitle,
            detail: batchResultDetail,
            symbol: failedCount == 0
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill",
            tint: failedCount == 0 ? PPColor.mint : PPColor.amber,
            metrics: [
                WorkflowMetric(
                    value: formattedResultInputSize,
                    label: "Input",
                    symbol: "internaldrive",
                    tint: PPColor.textSecondary
                ),
                WorkflowMetric(
                    value: formattedResultOutputSize,
                    label: "Output",
                    symbol: "arrow.down.right",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: resultSavings,
                    label: "Saved",
                    symbol: "chart.line.downtrend.xyaxis",
                    tint: PPColor.mint
                )
            ]
        )
    }

    private func resultRow(
        _ result: CompressionTaskResult
    ) -> some View {
        let alreadyOptimized = isAlreadyOptimized(result)
        return Button {
            guard let outputID = result.outputID else { return }
            onOpen(DocumentRoute(recordID: outputID))
        } label: {
            HStack(spacing: PPSpacing.medium) {
                Image(
                    systemName: result.outputID != nil
                        ? "checkmark.circle.fill"
                        : alreadyOptimized
                            ? "minus.circle"
                            : "xmark.circle.fill"
                )
                .font(.title3)
                .foregroundStyle(
                    result.outputID != nil ? PPColor.mint
                        : alreadyOptimized ? PPColor.textSecondary : Color.red
                )
                .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.outputName ?? result.sourceName)
                        .font(.body.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(2)
                    Text(resultDetail(result))
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }

                Spacer(minLength: PPSpacing.small)

                if result.outputID != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PPColor.accent)
                }
            }
            .padding(.vertical, PPSpacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(result.outputID == nil)
        .accessibilityHint(
            result.outputID == nil
                ? (
                    result.issue?.message.localizedUI
                        ?? "Compression failed".localizedUI
                )
                : "Opens the updated document."
                    .localizedUI
        )
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: PPSpacing.small) {
            if operationTask != nil {
                HStack {
                    Text(
                        operationStopRequested
                            ? "Finishing current file commit".localizedUI
                            : AppLocalization.format(
                                "Compressing %lld of %lld",
                                min(
                                    completedCount + 1,
                                    activeCompressionCount
                                ),
                                activeCompressionCount
                            )
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .monospacedDigit()
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    interruptBatchCompression()
                } label: {
                    Label(
                        operationStopRequested ? "Stopping" : "Stop",
                        systemImage: operationStopRequested
                            ? "hourglass"
                            : "stop.fill"
                    )
                        .frame(minHeight: 44)
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
                .disabled(operationStopRequested)
            } else if importTask != nil {
                if let progress = model.foregroundImportProgress(
                    for: importGeneration
                ) {
                    LocalOperationProgressView(progress: progress)
                        .accessibilityIdentifier(
                            "batchCompressionImportProgress"
                        )
                } else {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Importing PDFs".localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textSecondary)
                        Spacer()
                    }
                }
                Button {
                    cancelImport()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(minHeight: 44)
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
            } else if hasCompletedBatch {
                if !retryableCompressionIDs.isEmpty {
                    Button {
                        startCompression(
                            recordIDs: retryableCompressionIDs
                        )
                    } label: {
                        Label(
                            AppLocalization.format(
                                "Retry %lld Failed",
                                retryableCompressionIDs.count
                            ),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.amber)
                    )
                }
                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(PPPrimaryButtonStyle())
            } else {
                Button {
                    startCompression()
                } label: {
                    Label(
                        selectedIDs.isEmpty
                            ? "Choose PDFs".localizedUI
                            : AppLocalization.format(
                                "Compress %lld PDF%@",
                                selectedIDs.count,
                                selectedIDs.count == 1 ? "" : "s"
                            ),
                        systemImage:
                            "arrow.down.right.and.arrow.up.left"
                    )
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(selectedIDs.isEmpty || hasActiveTask)
                .accessibilityHint(
                    selectedIDs.isEmpty
                        ? "Choose at least one unlocked PDF."
                            .localizedUI
                        : hasActiveTask
                            ? "Wait for PDF import to finish."
                                .localizedUI
                            : "Updates each selected document. Previous versions are available in History."
                                .localizedUI
                )
                .accessibilityIdentifier("batchCompressionAction")
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

    private var availableRecords: [DocumentRecord] {
        model.workingDocuments.filter {
            $0.workflowStatus != .archived
        }
    }

    private var selectedRecords: [DocumentRecord] {
        selectedIDs.compactMap(model.record(id:))
    }

    private var hasActiveTask: Bool {
        importTask != nil || operationTask != nil
    }

    private var formattedSelectedSize: String {
        ByteCountFormatter.string(
            fromByteCount: selectedRecords.reduce(0) {
                let (next, overflow) = $0.addingReportingOverflow(
                    max(0, $1.profile.byteCount)
                )
                return overflow ? .max : next
            },
            countStyle: .file
        )
    }

    private var successfulCount: Int {
        results.filter { $0.outputID != nil }.count
    }

    private var alreadyOptimizedCount: Int {
        results.filter(isAlreadyOptimized).count
    }

    private var failedCount: Int {
        max(0, results.count - successfulCount - alreadyOptimizedCount)
    }

    private var batchOutputState: PDFCompressionBatchOutputState {
        PDFCompressionBatchOutputState(
            successfulCount: successfulCount,
            unchangedCount: alreadyOptimizedCount,
            failedCount: failedCount
        )
    }

    private var batchResultTitle: String {
        if failedCount > 0, failedCount == results.count {
            return "Compression failed".localizedUI
        }
        if successfulCount == 0,
           alreadyOptimizedCount == results.count,
           !results.isEmpty {
            return "Originals already smaller".localizedUI
        }
        return AppLocalization.format(
            "%lld smaller · %lld original%@ kept",
            successfulCount,
            alreadyOptimizedCount,
            alreadyOptimizedCount == 1 ? "" : "s"
        )
    }

    private var batchResultDetail: String {
        if failedCount > 0 {
            return AppLocalization.format(
                "%lld PDF%@ could not be processed.",
                failedCount,
                failedCount == 1 ? "" : "s"
            )
        }
        if alreadyOptimizedCount > 0 {
            return "Documents were left unchanged when compression did not reduce their size."
                .localizedUI
        }
        return "The selected documents were updated. Previous versions are in History.".localizedUI
    }

    private var retryableCompressionIDs: [UUID] {
        results.compactMap { result in
            guard result.outputID == nil,
                  result.issue?.isRetryable != false,
                  model.record(id: result.sourceID) != nil
            else { return nil }
            return result.sourceID
        }
    }

    private var resultInputBytes: Int64 {
        results.reduce(Int64.zero) { partial, result in
            let (next, overflow) = partial.addingReportingOverflow(
                max(0, result.sourceByteCount)
            )
            return overflow ? .max : next
        }
    }

    private var resultOutputBytes: Int64 {
        results.reduce(Int64.zero) { partial, result in
            let (next, overflow) = partial.addingReportingOverflow(
                max(0, result.outputByteCount ?? 0)
            )
            return overflow ? .max : next
        }
    }

    private var formattedResultInputSize: String {
        ByteCountFormatter.string(
            fromByteCount: resultInputBytes,
            countStyle: .file
        )
    }

    private var formattedResultOutputSize: String {
        if let placeholder = batchOutputState.placeholder {
            return placeholder.localizedUI
        }
        return ByteCountFormatter.string(
            fromByteCount: resultOutputBytes,
            countStyle: .file
        )
    }

    private var resultSavings: String {
        let compressedInputBytes = results.reduce(Int64.zero) {
            partial,
            result in
            guard result.outputID != nil else { return partial }
            let (next, overflow) = partial.addingReportingOverflow(
                max(0, result.sourceByteCount)
            )
            return overflow ? .max : next
        }
        guard compressedInputBytes > 0,
              resultOutputBytes < compressedInputBytes
        else { return "0%" }
        return "\(Int((1 - Double(resultOutputBytes) / Double(compressedInputBytes)) * 100))%"
    }

    private func toggle(_ id: UUID) {
        importErrorMessage = nil
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(id)
        }
    }

    private func cancelImport(
        showsNotice: Bool = false
    ) {
        let hadActiveImport = importTask != nil
        let cancelledProgressID = importGeneration
        importGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        model.clearForegroundImportProgress(
            cancelledProgressID
        )
        if showsNotice, hadActiveImport {
            model[noticeFor: paperPathSceneID] =
                "PDF import stopped · finished copies stay in the Library"
                    .localizedUI
        }
    }

    private func presentImportError(_ message: String) {
        importErrorMessage = message
        failureFeedback += 1
    }

    private func interruptBatchCompression(
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
            currentRecordID = nil
            activeCompressionCount = 0
            if !results.isEmpty {
                hasCompletedBatch = true
            }
        }
    }

    private func resultDetail(
        _ result: CompressionTaskResult
    ) -> String {
        guard let outputByteCount = result.outputByteCount else {
            return result.issue?.message.localizedUI
                ?? "Compression failed".localizedUI
        }
        let original = ByteCountFormatter.string(
            fromByteCount: result.sourceByteCount,
            countStyle: .file
        )
        let output = ByteCountFormatter.string(
            fromByteCount: outputByteCount,
            countStyle: .file
        )
        guard outputByteCount < result.sourceByteCount,
              result.sourceByteCount > 0
        else {
            return "\(original) → \(output)"
        }
        let savings = Int(
            (
                1
                    - Double(outputByteCount)
                    / Double(result.sourceByteCount)
            ) * 100
        )
        return AppLocalization.format(
            "%@ → %@ · %lld%% smaller",
            original,
            output,
            savings
        )
    }

    private func isAlreadyOptimized(
        _ result: CompressionTaskResult
    ) -> Bool {
        result.outputID == nil && result.issue?.code == "V-102"
    }

    private func startCompression(
        recordIDs: [UUID]? = nil
    ) {
        guard operationTask == nil,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        let sources = (recordIDs ?? selectedIDs)
            .compactMap(model.record(id:))
        guard !sources.isEmpty else { return }
        let generation = UUID()
        operationGeneration = generation
        operationStopRequested = false
        let requestedQuality: PDFCompressionQuality = compressionMode == .optimizedImages ? .readable : quality
        let requestedMode = compressionMode
        if recordIDs == nil {
            results = []
        }
        completedCount = 0
        activeCompressionCount = sources.count
        hasCompletedBatch = false
        operationTask = Task { @MainActor in
            await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await runCompression(
                    generation: generation,
                    quality: requestedQuality,
                    mode: requestedMode,
                    sources: sources
                )
            }
        }
    }

    private func runCompression(
        generation: UUID,
        quality: PDFCompressionQuality,
        mode: PDFCompressionMode,
        sources: [DocumentRecord]
    ) async {
        guard !sources.isEmpty else {
            if operationGeneration == generation {
                operationTask = nil
            }
            return
        }

        defer {
            if operationGeneration == generation {
                let wasStopped =
                    operationStopRequested || Task.isCancelled
                currentRecordID = nil
                activeCompressionCount = 0
                operationTask = nil
                operationStopRequested = false
                if !results.isEmpty {
                    hasCompletedBatch = true
                }
                if wasStopped {
                    model[noticeFor: paperPathSceneID] = (
                        successfulCount > 0
                            ? "Compression stopped · finished copies kept in Library"
                            : "Compression stopped"
                    ).localizedUI
                }
            }
        }

        for source in sources {
            if Task.isCancelled { break }
            guard operationGeneration == generation else { return }
            currentRecordID = source.id
            var issue: PDFBatchDeliveryIssue?
            let created = await model.createCompressedCopy(
                recordID: source.id,
                quality: quality,
                mode: mode,
                expectedContentRevisionID:
                    source.contentRevisionID,
                presentsFeedback: false
            ) {
                issue = $0
            }
            guard operationGeneration == generation else { return }
            replaceCompressionResult(
                CompressionTaskResult(
                    sourceID: source.id,
                    sourceName: source.displayName,
                    sourceByteCount: source.profile.byteCount,
                    outputID: created?.id,
                    outputName: created?.displayName,
                    outputByteCount: created?.profile.byteCount,
                    issue: issue
                )
            )
            completedCount += 1
            if issue?.phase == .cancelled { break }
        }

        guard !Task.isCancelled else { return }
        if successfulCount == 0,
           alreadyOptimizedCount == results.count,
           !results.isEmpty {
            model[noticeFor: paperPathSceneID] =
                "The selected PDFs are already smaller. PaperPath kept the originals."
                    .localizedUI
        } else if batchOutputState == .unavailable {
            model[noticeFor: paperPathSceneID] =
                "No PDFs were compressed. Review the results.".localizedUI
        } else {
            model[noticeFor: paperPathSceneID] = AppLocalization.format(
                "%lld compressed cop%@ ready",
                successfulCount,
                successfulCount == 1 ? "y" : "ies"
            )
        }
    }

    private func replaceCompressionResult(
        _ result: CompressionTaskResult
    ) {
        if let index = results.firstIndex(where: {
            $0.sourceID == result.sourceID
        }) {
            results[index] = result
        } else {
            results.append(result)
        }
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

struct CompressionSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    @AppStorage("privacy.hideLibraryPreviews") private var hideSourcePreview = false

    let recordID: UUID
    let onCreated: (DocumentRoute) -> Void
    @State private var quality: PDFCompressionQuality = .readable
    @State private var compressionMode = PDFCompressionMode.preserveContent
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var operationStopRequested = false
    @State private var estimate: PDFCompressionEstimate?
    @State private var estimateFailed = false
    @State private var estimateTask: Task<Void, Never>?
    @State private var estimateGeneration = UUID()
    @State private var operationNoticeMessage: String?
    @State private var operationErrorMessage: String?
    @State private var errorFeedback = 0
    @State private var sourceContentRevisionID: UUID?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                if let record = model.record(id: recordID) {
                    ScrollView {
                        VStack(
                            alignment: .leading,
                            spacing: PPSpacing.large
                        ) {
                            HStack(spacing: PPSpacing.medium) {
                                if !hideSourcePreview, let url = model.url(for: recordID) {
                                    PDFPageThumbnailView(
                                        url: url, pageIndex: 0,
                                        refreshToken: model.refreshToken(for: recordID), width: 52
                                    )
                                }
                                VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                                    Text(record.displayName)
                                        .font(.headline)
                                        .foregroundStyle(PPColor.textPrimary)
                                    Text(record.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(PPColor.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, PPSpacing.small)

                            CompressionModePicker(selection: $compressionMode)
                                .disabled(operationTask != nil)
                            if compressionMode == .imageCopy {
                                Text("Compression quality".localizedUI)
                                    .font(.subheadline.weight(.semibold))
                                CompressionQualityPicker(selection: $quality)
                                    .disabled(operationTask != nil)
                                Text(quality.detail.localizedUI)
                                    .font(.caption)
                                    .foregroundStyle(PPColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            VStack(spacing: PPSpacing.medium) {
                                LabeledContent("Original size".localizedUI, value: record.profile.formattedSize)
                                Divider()
                                LabeledContent((compressionMode != .imageCopy ? "Output size" : "Estimated size").localizedUI, value: compressionMode != .imageCopy
                                    ? "Measured after compression".localizedUI
                                    : estimate?.formattedSize ?? (estimateFailed ? "Unavailable".localizedUI : "—"))
                                if estimate == nil && !estimateFailed {
                                    HStack(spacing: PPSpacing.small) {
                                        ProgressView().controlSize(.small)
                                        Text("Checking on device".localizedUI)
                                        Spacer()
                                    }
                                    .font(.caption)
                                    .foregroundStyle(PPColor.textSecondary)
                                }
                            }
                            .font(.subheadline.monospacedDigit())
                            .padding(PPSpacing.regular)
                            .background(PPColor.surfaceMuted, in: RoundedRectangle(cornerRadius: PPRadius.control))
                            .accessibilityIdentifier("compressionSizeEstimate")

                            if compressionMode == .imageCopy {
                                OperationBoundaryNotice(
                                    title: compressionMode.title,
                                    detail: compressionMode.detail,
                                    identifier: "compressionOutputBoundary"
                                )
                            } else {
                                Text(compressionMode.detail.localizedUI)
                                    .font(.caption)
                                    .foregroundStyle(PPColor.textSecondary)
                                    .accessibilityIdentifier("compressionOutputBoundary")
                            }

                            if let estimate, compressionMode == .imageCopy {
                                compressionEstimateStatus(estimate)
                            }
                            if estimateFailed {
                                HStack(spacing: PPSpacing.small) {
                                    Label(
                                        "Size estimate unavailable",
                                        systemImage:
                                            "exclamationmark.circle"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(PPColor.amber)
                                    Spacer(minLength: PPSpacing.small)
                                    Button("Retry".localizedUI) {
                                        startEstimate()
                                    }
                                    .buttonStyle(
                                        PPQuietButtonStyle(
                                            tint: PPColor.amber
                                        )
                                    )
                                }
                            }
                            if let operationNoticeMessage {
                                Label(
                                    operationNoticeMessage,
                                    systemImage: "checkmark.shield.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(PPColor.mint)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                            }
                            if operationNoticeMessage != nil, compressionMode == .preserveContent {
                                Button("Try high-quality compression (lossy)".localizedUI) {
                                    quality = .readable
                                    compressionMode = .optimizedImages
                                    startCompression()
                                }
                                .buttonStyle(PPQuietButtonStyle(tint: PPColor.accent))
                                .accessibilityIdentifier("compressionTryLossyAction")
                            }
                            if let operationErrorMessage {
                                Label(
                                    operationErrorMessage,
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

                            if let progress = model.progress(
                                for: recordID
                            ) {
                                LocalOperationProgressView(progress: progress)
                                Text("Large PDFs may take a few minutes. Keep PaperPath open. Stop keeps your original.".localizedUI)
                                    .font(.caption)
                                    .foregroundStyle(PPColor.textSecondary)
                            }
                        }
                        .frame(maxWidth: 680)
                        .padding(PPSpacing.regular)
                        .padding(.bottom, 76)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: PPSpacing.small) {
                    Button {
                        startCompression()
                    } label: {
                        Label(
                            compressionActionTitle,
                            systemImage: compressionActionSymbol
                        )
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .disabled(compressionActionDisabled)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(compressionActionHint)
                    .accessibilityIdentifier(
                        "compressionCreateAction"
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
            .navigationTitle("Compress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationTask == nil
                                ? "Cancel"
                                : operationStopRequested
                                    ? "Stopping"
                                    : "Stop"
                        ).localizedUI
                    ) {
                        if operationTask != nil {
                            interruptCompressionWork()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(operationStopRequested)
                }
            }
        }
        .onAppear {
            sourceContentRevisionID = model.record(id: recordID)?
                .contentRevisionID
            startEstimate()
        }
        .onChange(of: quality) { startEstimate() }
        .onChange(of: compressionMode) { startEstimate() }
        .onChange(
            of: model.record(id: recordID)?
                .contentRevisionID
        ) { oldRevisionID, newRevisionID in
            guard oldRevisionID != newRevisionID, newRevisionID != sourceContentRevisionID,
                  operationTask == nil else { return }
            interruptCompressionWork(invalidateResult: true)
            sourceContentRevisionID = newRevisionID
            estimate = nil
            estimateFailed = false
            guard newRevisionID != nil,
                  scenePhase == .active,
                  UIApplication.shared
                    .isProtectedDataAvailable
            else { return }
            model[noticeFor: paperPathSceneID] =
                "PDF updated · estimate refreshed".localizedUI
            startEstimate()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, estimate == nil {
                startEstimate()
            } else if phase == .background {
                interruptCompressionWork(invalidateResult: true)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptCompressionWork(invalidateResult: true)
        }
        .onDisappear {
            interruptCompressionWork(invalidateResult: true)
        }
        .interactiveDismissDisabled(operationTask != nil)
        .sensoryFeedback(.error, trigger: errorFeedback)
    }

    @ViewBuilder
    private func compressionEstimateStatus(
        _ estimate: PDFCompressionEstimate
    ) -> some View {
        if estimate.isBeneficial {
            Label(
                estimate.summary,
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
        } else {
            Label(
                "Sample suggests little saving. You can still try; the document is updated only if smaller and verified.".localizedUI,
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .accessibilityIdentifier("compressionAlreadyOptimized")
        }
    }

    private func startEstimate() {
        guard operationTask == nil, let sourceContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == sourceContentRevisionID
        else { return }
        estimateGeneration = UUID()
        let generation = estimateGeneration
        let requestedQuality = quality
        let requestedMode = compressionMode
        estimateTask?.cancel()
        estimate = nil
        estimateFailed = false
        operationNoticeMessage = nil
        operationErrorMessage = nil
        estimateTask = Task { @MainActor in
            defer {
                if estimateGeneration == generation {
                    estimateTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
                let loaded = try await model.withFeedbackTarget(
                    paperPathSceneID
                ) {
                    try await model.compressionEstimate(
                        recordID: recordID,
                        quality: requestedQuality,
                        mode: requestedMode,
                        expectedContentRevisionID:
                            sourceContentRevisionID
                    )
                }
                guard !Task.isCancelled,
                      estimateGeneration == generation,
                      quality == requestedQuality,
                      compressionMode == requestedMode,
                      model.record(id: recordID)?
                        .contentRevisionID
                        == sourceContentRevisionID
                else { return }
                estimate = loaded
            } catch is CancellationError {
                return
            } catch {
                guard estimateGeneration == generation else { return }
                estimateFailed = true
                errorFeedback += 1
            }
        }
    }

    private func interruptCompressionWork(
        invalidateResult: Bool = false
    ) {
        estimateGeneration = UUID()
        estimateTask?.cancel()
        estimateTask = nil
        if invalidateResult {
            operationGeneration = UUID()
            operationStopRequested = false
        } else if operationTask != nil {
            guard !operationStopRequested else { return }
            operationStopRequested = true
        }
        operationTask?.cancel()
        if invalidateResult {
            operationTask = nil
            operationNoticeMessage = nil
            operationErrorMessage = nil
        }
    }

    private func startCompression() {
        guard operationTask == nil,
              let sourceContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == sourceContentRevisionID,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        operationNoticeMessage = nil
        operationErrorMessage = nil
        operationStopRequested = false
        let generation = UUID()
        operationGeneration = generation
        let requestedQuality: PDFCompressionQuality = compressionMode == .optimizedImages ? .readable : quality
        let requestedMode = compressionMode
        estimateGeneration = UUID()
        estimateTask?.cancel()
        estimateTask = nil
        operationTask = Task { @MainActor in
            var operationIssue: PDFBatchDeliveryIssue?
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createCompressedCopy(
                    recordID: recordID,
                    quality: requestedQuality,
                    mode: requestedMode,
                    expectedContentRevisionID:
                        sourceContentRevisionID,
                    presentsFeedback: false
                ) {
                    operationIssue = $0
                }
            }
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            if let created { self.sourceContentRevisionID = created.contentRevisionID }
            operationTask = nil
            operationStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    created == nil
                        ? "Changes stopped"
                        : "Document saved before stopping"
                ).localizedUI
                return
            }
            guard let created else {
                if !Task.isCancelled {
                    if operationIssue?.code == "V-102" {
                        operationNoticeMessage = operationIssue?
                            .message.localizedUI
                    } else {
                        operationErrorMessage = operationIssue?
                            .message.localizedUI
                            ?? "Compression failed. The document and quality setting are unchanged."
                                .localizedUI
                        errorFeedback += 1
                    }
                }
                return
            }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private var compressionActionHint: String {
        if operationTask != nil {
            return "Wait for compression to finish.".localizedUI
        }
        return "Updates this document. The previous version is available in History."
            .localizedUI
    }

    private var compressionActionTitle: String {
        if operationStopRequested {
            return "Finishing current file commit".localizedUI
        }
        if operationTask != nil {
            return "Compressing".localizedUI
        }
        return "Compress PDF".localizedUI
    }

    private var compressionActionSymbol: String {
        if operationTask != nil {
            return "hourglass"
        }
        return "arrow.down.right.and.arrow.up.left"
    }

    private var compressionActionDisabled: Bool {
        operationTask != nil
    }
}

struct ProtectionSheet: View {
    private enum PermissionProfile: String, CaseIterable, Identifiable {
        case restricted
        case review
        case flexible
        case custom

        var id: String { rawValue }
        var title: String {
            switch self {
            case .restricted: return "Restricted"
            case .review: return "Review"
            case .flexible: return "Flexible"
            case .custom: return "Custom"
            }
        }
    }

    private enum PasswordField: Hashable {
        case password
        case confirmation
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let onCreated: (DocumentRoute) -> Void
    @State private var password = ""
    @State private var confirmation = ""
    @State private var permissions = PDFProtectionPermissions.restricted
    @State private var permissionProfile = PermissionProfile.restricted
    @State private var showsPermissionDetails = false
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var operationStopRequested = false
    @State private var operationErrorMessage: String?
    @State private var errorFeedback = 0
    @State private var isConfirmingDiscard = false
    @State private var sourceContentRevisionID: UUID?
    @State private var requiresUpdatedPDFConfirmation = false
    @FocusState private var focusedPasswordField: PasswordField?

    private var validationMessage: String? {
        PDFProtectionPasswordValidation.message(
            password: password,
            confirmation: confirmation
        )
    }

    private var visibleValidationMessage: String? {
        if password.count > 128 || confirmation.count > 128 {
            return validationMessage
        }
        if focusedPasswordField == .password, password.count < 8 {
            return nil
        }
        if confirmation.isEmpty, password.count >= 8 {
            return nil
        }
        if focusedPasswordField == .confirmation,
           confirmation.count < password.count,
           password.hasPrefix(confirmation) {
            return nil
        }
        return validationMessage
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
                            eyebrow: "PROTECTION WORKFLOW",
                            title: "Protect PDF",
                            detail: "Updates this document. The previous version is available in History.",
                            symbol: "lock.doc",
                            tint: PPColor.amber,
                            metrics: [],
                            showsOnDevice: true
                        )

                        VStack(alignment: .leading, spacing: PPSpacing.small) {
                            WorkflowSectionHeader(
                                eyebrow: "OPEN PASSWORD",
                                title: "Required to open"
                            )
                            Text("Use at least eight characters.".localizedUI)
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                            securePasteField(
                                "Password",
                                text: $password,
                                field: .password
                            )
                            securePasteField(
                                "Confirm password",
                                text: $confirmation,
                                field: .confirmation
                            )
                            if let visibleValidationMessage {
                                Label(
                                    visibleValidationMessage.localizedUI,
                                    systemImage: "exclamationmark.circle"
                                )
                                .font(.caption)
                                .foregroundStyle(PPColor.amber)
                                .accessibilityIdentifier("protectionValidation")
                            }
                            Text(
                                "PaperPath does not store this password. Keep it safe to reopen this PDF. Earlier versions in History may be unencrypted."
                            )
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: PPSpacing.small) {
                            WorkflowSectionHeader(
                                eyebrow: "PERMISSIONS",
                                title: "Allowed after opening",
                                count: allowedPermissionCount,
                                tint: PPColor.cyan
                            )
                            permissionProfilePicker
                            Text(permissionProfileDetail.localizedUI)
                                .font(.subheadline)
                                .foregroundStyle(PPColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        DisclosureGroup(isExpanded: $showsPermissionDetails) {
                            permissionDetails
                        } label: {
                            Label(
                                "Customize permissions".localizedUI,
                                systemImage: "slider.horizontal.3"
                            )
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("protectionPermissionDetails")

                        OperationBoundaryNotice(
                            title: "Password and permissions differ",
                            detail: "The password locks the file. Other restrictions depend on the PDF reader.",
                            identifier: "protectionPermissionBoundary",
                            symbol: "lock.trianglebadge.exclamationmark"
                        )

                    if let progress = model.progress(for: recordID) {
                        LocalOperationProgressView(progress: progress)
                    }
                    if let operationErrorMessage {
                        Label(
                            operationErrorMessage,
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.rose)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    }
                    .frame(maxWidth: 720)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 72)
                    .frame(maxWidth: .infinity)
                    .disabled(operationTask != nil)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                    Button {
                        if requiresUpdatedPDFConfirmation {
                            confirmUpdatedPDFForProtection()
                        } else {
                            startProtection()
                        }
                    } label: {
                        Label(
                            operationStopRequested
                                ? "Finishing current file commit"
                                : operationTask == nil
                                    ? (
                                        requiresUpdatedPDFConfirmation
                                            ? "Confirm Updated PDF"
                                            : "Protect PDF"
                                    )
                                    : "Protecting PDF",
                            systemImage: operationTask == nil
                                ? (
                                    requiresUpdatedPDFConfirmation
                                        ? "arrow.clockwise"
                                        : "lock.doc"
                                )
                                : "hourglass"
                        )
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .disabled(
                        validationMessage != nil
                            || password.isEmpty
                            || operationTask != nil
                            || sourceContentRevisionID == nil
                    )
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(protectionActionHint)
                    .accessibilityIdentifier(
                        "protectionCreateAction"
                    )
                    .padding(.horizontal, PPSpacing.regular)
                    .padding(.vertical, PPSpacing.small)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.62))
                            .frame(height: 0.6)
                    }
            }
            .navigationTitle("Protect PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationTask == nil
                                ? "Cancel"
                                : operationStopRequested
                                    ? "Stopping"
                                    : "Stop"
                        ).localizedUI
                    ) {
                        if operationTask != nil {
                            interruptProtection()
                        } else {
                            requestProtectionDismissal()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(operationStopRequested)
                }
            }
            .onChange(of: password) { _, _ in
                operationErrorMessage = nil
            }
            .onChange(of: confirmation) { _, _ in
                operationErrorMessage = nil
            }
            .onChange(of: permissionProfile) { _, profile in
                applyPermissionProfile(profile)
                if profile == .custom {
                    showsPermissionDetails = true
                }
            }
            .onChange(of: permissions) { _, permissions in
                let resolved = profile(for: permissions)
                if permissionProfile != resolved {
                    permissionProfile = resolved
                }
                operationErrorMessage = nil
            }
        }
        .onAppear {
            sourceContentRevisionID = model.record(id: recordID)?
                .contentRevisionID
        }
        .confirmationDialog(
            "Discard protection setup?".localizedUI,
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(
                "Discard Setup".localizedUI,
                role: .destructive
            ) {
                password = ""
                confirmation = ""
                dismiss()
            }
            Button("Keep Editing".localizedUI, role: .cancel) {}
        } message: {
            Text(
                "The password and permission changes have not been saved."
                    .localizedUI
            )
        }
        .onDisappear {
            interruptProtection(invalidateResult: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptProtection(invalidateResult: true)
        }
        .onChange(
            of: model.record(id: recordID)?
                .contentRevisionID
        ) { oldRevisionID, newRevisionID in
            guard oldRevisionID != newRevisionID, newRevisionID != sourceContentRevisionID,
                  operationTask == nil else { return }
            invalidateProtectionOperationForSourceChange()
            sourceContentRevisionID = newRevisionID
            requiresUpdatedPDFConfirmation = newRevisionID != nil
            operationErrorMessage =
                "The PDF changed. Review these settings before saving."
                    .localizedUI
            errorFeedback += 1
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtection(invalidateResult: true)
        }
        .interactiveDismissDisabled(
            operationTask != nil || hasProtectionDraft
        )
        .sensoryFeedback(.error, trigger: errorFeedback)
    }

    @ViewBuilder
    private var permissionProfilePicker: some View {
        let picker = Picker(
            "Permission profile",
            selection: $permissionProfile
        ) {
            ForEach(
                PermissionProfile.allCases.filter { $0 != .custom }
            ) { profile in
                Text(profile.title.localizedUI)
                    .tag(profile)
            }
            if permissionProfile == .custom {
                Text(PermissionProfile.custom.title.localizedUI)
                    .tag(PermissionProfile.custom)
                    .disabled(true)
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

    @ViewBuilder
    private func securePasteField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        field: PasswordField
    ) -> some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            VStack(alignment: .trailing, spacing: PPSpacing.small) {
                secureField(title, text: text, field: field)
                passwordPasteButton(text: text)
            }
        } else {
            HStack(spacing: PPSpacing.small) {
                secureField(title, text: text, field: field)
                passwordPasteButton(text: text)
            }
        }
    }

    private func secureField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        field: PasswordField
    ) -> some View {
        SecureField(title, text: text)
            .textContentType(.newPassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focusedPasswordField, equals: field)
            .submitLabel(
                field == .password ? .next : .done
            )
            .onSubmit {
                if field == .password {
                    focusedPasswordField = .confirmation
                } else if validationMessage == nil,
                          !password.isEmpty {
                    if requiresUpdatedPDFConfirmation {
                        confirmUpdatedPDFForProtection()
                    } else {
                        startProtection()
                    }
                }
            }
            .padding(.horizontal, PPSpacing.medium)
            .frame(minHeight: 44)
            .background(
                PPColor.surface,
                in: RoundedRectangle(cornerRadius: PPRadius.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PPRadius.control)
                    .stroke(
                        focusedPasswordField == field
                            ? PPColor.accent
                            : PPColor.border,
                        lineWidth: 1
                    )
            }
            .accessibilityIdentifier(
                field == .password
                    ? "protectionPassword"
                    : "protectionConfirmation"
            )
    }

    private func passwordPasteButton(
        text: Binding<String>
    ) -> some View {
        PasteButton(payloadType: String.self) { values in
            guard let value = values.first else { return }
            text.wrappedValue = value
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint(
            "Pastes the password without storing it in PaperPath"
        )
    }

    private var allowedPermissionCount: Int {
        [
            permissions.allowsPrinting,
            permissions.allowsCopying,
            permissions.allowsCommenting,
            permissions.allowsFormFilling,
            permissions.allowsPageChanges
        ].filter { $0 }.count
    }

    private var permissionProfileDetail: String {
        switch permissionProfile {
        case .restricted:
            return "Allow printing, comments, and form filling. Copying and page changes are restricted."
        case .review:
            return "Allow comments and form filling. Printing, copying, and page changes are restricted."
        case .flexible:
            return "Allow printing, copying, comments, form filling, and page changes."
        case .custom:
            return "Choose what readers can do after opening this PDF."
        }
    }

    private var permissionDetails: some View {
        VStack(spacing: PPSpacing.medium) {
            Toggle("Print", isOn: $permissions.allowsPrinting)
            Toggle("Copy text and images", isOn: $permissions.allowsCopying)
            Toggle(
                "Comments and annotations",
                isOn: Binding(
                    get: { permissions.allowsCommenting },
                    set: { enabled in
                        permissions.allowsCommenting = enabled
                        if enabled {
                            permissions.allowsFormFilling = true
                        }
                    }
                )
            )
            Toggle("Fill forms", isOn: $permissions.allowsFormFilling)
                .disabled(permissions.allowsCommenting)
                .accessibilityHint(
                    permissions.allowsCommenting
                        ? "Form filling is required when comments are allowed."
                            .localizedUI
                        : "Controls whether forms can be filled after opening."
                            .localizedUI
                )
            Toggle(
                "Insert, remove, or rotate pages",
                isOn: $permissions.allowsPageChanges
            )
        }
        .padding(.vertical, PPSpacing.small)
    }

    private var hasProtectionDraft: Bool {
        !password.isEmpty
            || !confirmation.isEmpty
            || permissions != .restricted
    }

    private var protectionActionHint: String {
        if operationTask != nil {
            return "Wait for password protection to finish."
                .localizedUI
        }
        if password.isEmpty {
            return "Enter and confirm a password first."
                .localizedUI
        }
        if requiresUpdatedPDFConfirmation {
            return "Reviews these settings without changing the PDF."
                .localizedUI
        }
        if let validationMessage {
            return validationMessage.localizedUI
        }
        return "Creates a separate password-protected PDF."
            .localizedUI
    }

    private func applyPermissionProfile(
        _ profile: PermissionProfile
    ) {
        switch profile {
        case .restricted:
            permissions = .restricted
        case .review:
            permissions = PDFProtectionPermissions(
                allowsPrinting: false,
                allowsCopying: false,
                allowsCommenting: true,
                allowsFormFilling: true,
                allowsPageChanges: false
            )
        case .flexible:
            permissions = PDFProtectionPermissions(
                allowsPrinting: true,
                allowsCopying: true,
                allowsCommenting: true,
                allowsFormFilling: true,
                allowsPageChanges: true
            )
        case .custom:
            break
        }
    }

    private func profile(
        for permissions: PDFProtectionPermissions
    ) -> PermissionProfile {
        if permissions == .restricted {
            return .restricted
        }
        if permissions == PDFProtectionPermissions(
            allowsPrinting: false,
            allowsCopying: false,
            allowsCommenting: true,
            allowsFormFilling: true,
            allowsPageChanges: false
        ) {
            return .review
        }
        if permissions == PDFProtectionPermissions(
            allowsPrinting: true,
            allowsCopying: true,
            allowsCommenting: true,
            allowsFormFilling: true,
            allowsPageChanges: true
        ) {
            return .flexible
        }
        return .custom
    }

    private func startProtection() {
        guard !password.isEmpty,
              validationMessage == nil,
              operationTask == nil,
              !requiresUpdatedPDFConfirmation,
              let sourceContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == sourceContentRevisionID,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        operationErrorMessage = nil
        operationStopRequested = false
        focusedPasswordField = nil
        let generation = UUID()
        operationGeneration = generation
        let requestedPassword = password
        let requestedPermissions = permissions
        operationTask = Task { @MainActor in
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createProtectedCopy(
                    recordID: recordID,
                    password: requestedPassword,
                    permissions: requestedPermissions,
                    expectedContentRevisionID:
                        sourceContentRevisionID
                )
            }
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            if let created { self.sourceContentRevisionID = created.contentRevisionID }
            operationTask = nil
            operationStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    created == nil
                        ? "Changes stopped"
                        : "Document saved before stopping"
                ).localizedUI
                return
            }
            guard let created else {
                if !Task.isCancelled {
                    operationErrorMessage =
                        "Protection failed. Password and permissions are unchanged."
                            .localizedUI
                    errorFeedback += 1
                }
                return
            }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func confirmUpdatedPDFForProtection() {
        guard let revisionID =
                model.record(id: recordID)?.contentRevisionID
        else { return }
        sourceContentRevisionID = revisionID
        requiresUpdatedPDFConfirmation = false
        operationErrorMessage = nil
    }

    private func invalidateProtectionOperationForSourceChange() {
        operationGeneration = UUID()
        operationStopRequested = false
        operationTask?.cancel()
        operationTask = nil
        isConfirmingDiscard = false
        focusedPasswordField = nil
    }

    private func interruptProtection(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            operationGeneration = UUID()
            operationStopRequested = false
        } else if operationTask != nil {
            guard !operationStopRequested else { return }
            operationStopRequested = true
        }
        operationTask?.cancel()
        if invalidateResult {
            operationTask = nil
            operationErrorMessage = nil
            isConfirmingDiscard = false
        }
        focusedPasswordField = nil
        password = ""
        confirmation = ""
    }

    private func requestProtectionDismissal() {
        if hasProtectionDraft {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }
}

struct RedactionReviewSheet: View {
    private struct PageGroup: Identifiable {
        let pageIndex: Int
        let marks: [PDFRedactionMark]
        var id: Int { pageIndex }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    @Binding var marks: [PDFRedactionMark]
    let onReviewPage: (Int) -> Void
    let onCreated: (DocumentRoute) -> Void
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var operationStopRequested = false
    @State private var pageGroups: [PageGroup] = []
    @State private var isConfirmingClearMarks = false
    @State private var operationErrorMessage: String?
    @State private var errorFeedback = 0
    @State private var markFeedback = 0
    @State private var sourceContentRevisionID: UUID?
    @State private var sourceWasUpdated = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: PPSpacing.large) {
                        WorkflowCommandHeader(
                            eyebrow: "REDACTION WORKFLOW",
                            title: "Review marked areas",
                            detail: "Removes marked content from this document. Earlier versions in History still contain it.",
                            symbol: "eye.slash.fill",
                            tint: PPColor.amber,
                            metrics: [
                                WorkflowMetric(
                                    value: "\(marks.count)",
                                    label: "Areas",
                                    symbol: "selection.pin.in.out",
                                    tint: PPColor.amber
                                ),
                                WorkflowMetric(
                                    value: "\(Set(marks.map(\.pageIndex)).count)",
                                    label: "Pages",
                                    symbol: "doc.on.doc",
                                    tint: PPColor.accent
                                )
                            ],
                            showsOnDevice: true
                        )

                        OperationBoundaryNotice(
                            title: "Redaction rebuilds pages as images",
                            detail: "Removes marked content, search, links, forms, and editable notes.",
                            identifier: "redactionOutputBoundary",
                            symbol: "eye.slash.fill"
                        )

                        if marks.isEmpty {
                            VStack(spacing: PPSpacing.medium) {
                                PPEmptyState(
                                    kind: .workspace,
                                    title: "No marked areas",
                                    message: "Mark at least one area in the PDF."
                                )
                                Button {
                                    dismiss()
                                } label: {
                                    Label(
                                        "Mark Another Area",
                                        systemImage: "selection.pin.in.out"
                                    )
                                }
                                .buttonStyle(
                                    PPQuietButtonStyle(
                                        tint: PPColor.amber
                                    )
                                )
                            }
                            .padding(.vertical, PPSpacing.large)
                        } else {
                            VStack(spacing: 0) {
                            ForEach(pageGroups) { group in
                                HStack {
                                    Label(
                                        "Page \(group.pageIndex + 1)",
                                        systemImage: "doc.text"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(
                                        AppLocalization.format(
                                            "%@ area%@",
                                            "\(group.marks.count)",
                                            group.marks.count == 1 ? "" : "s"
                                        )
                                    )
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(
                                        PPColor.textSecondary
                                    )
                                }
                                .padding(.vertical, 6)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(
                                            PPColor.amber.opacity(0.42)
                                        )
                                        .frame(height: 1)
                                }

                                ForEach(
                                    Array(group.marks.enumerated()),
                                    id: \.offset
                                ) { localIndex, mark in
                                    HStack(spacing: PPSpacing.medium) {
                                        Button {
                                            onReviewPage(mark.pageIndex)
                                        } label: {
                                            HStack(
                                                spacing: PPSpacing.medium
                                            ) {
                                                Image(
                                                    systemName:
                                                        "selection.pin.in.out"
                                                )
                                                .foregroundStyle(
                                                    PPColor.textSecondary
                                                )
                                                .frame(width: 28)
                                                Text(
                                                    AppLocalization.format(
                                                        "Area %@",
                                                        "\(localIndex + 1)"
                                                    )
                                                )
                                                .font(
                                                    .body.weight(.semibold)
                                                )
                                                .foregroundStyle(
                                                    PPColor.textPrimary
                                                )
                                                Spacer(minLength: 0)
                                                Image(
                                                    systemName: "eye"
                                                )
                                                .font(.caption)
                                                .foregroundStyle(
                                                    PPColor.cyan
                                                )
                                            }
                                            .frame(
                                                maxWidth: .infinity,
                                                minHeight: 44,
                                                alignment: .leading
                                            )
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(operationTask != nil)
                                        .accessibilityLabel(
                                            AppLocalization.format(
                                                "Review marked area %lld on page %lld",
                                                localIndex + 1,
                                                mark.pageIndex + 1
                                            )
                                        )

                                        Button {
                                            if let index =
                                                marks.firstIndex(
                                                    of: mark
                                                ) {
                                                marks.remove(at: index)
                                            }
                                        } label: {
                                            Image(
                                                systemName:
                                                    "xmark.circle.fill"
                                            )
                                            .foregroundStyle(
                                                PPColor.textSecondary
                                            )
                                            .frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(operationTask != nil)
                                        .accessibilityLabel(
                                            AppLocalization.format(
                                                "Remove marked area %lld",
                                                localIndex + 1
                                            )
                                        )
                                    }
                                    .padding(.vertical, PPSpacing.small)
                                    .overlay(alignment: .bottom) {
                                        Rectangle()
                                            .fill(
                                                PPColor.border.opacity(
                                                    0.52
                                                )
                                            )
                                            .frame(height: 0.6)
                                            .padding(.leading, 44)
                                    }
                                }
                            }
                            }
                            .padding(.horizontal, PPSpacing.small)
                            .background(PPColor.surface.opacity(0.72))
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

                            HStack(spacing: PPSpacing.medium) {
                                Button("Add Another Area") {
                                    dismiss()
                                }
                                .buttonStyle(PPQuietButtonStyle())
                                .disabled(operationTask != nil)
                                Spacer()
                                Button(
                                    "Clear Marks",
                                    role: .destructive
                                ) {
                                    isConfirmingClearMarks = true
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                                .disabled(operationTask != nil)
                            }
                        }

                        if let operationErrorMessage {
                            Label(
                                operationErrorMessage,
                                systemImage: "exclamationmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.rose)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    startRedaction()
                } label: {
                    if operationTask == nil {
                        Label(
                            "Apply Redaction",
                            systemImage: "checkmark.shield"
                        )
                    } else {
                        Label(
                            operationStopRequested
                                ? "Finishing current file commit"
                                : "Applying Redaction",
                            systemImage: "hourglass"
                        )
                    }
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(marks.isEmpty || operationTask != nil)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(redactionActionHint)
                .accessibilityIdentifier("redactionCreateAction")
                .padding(.horizontal, PPSpacing.regular)
                .padding(.vertical, PPSpacing.small)
                .background(.bar)
                if let progress = model.progress(for: recordID) {
                    LocalOperationProgressView(progress: progress)
                        .padding(.horizontal, PPSpacing.xLarge)
                        .padding(.bottom, PPSpacing.medium)
                        .background(.bar)
                }
            }
            .background(PPColor.canvas)
            .navigationTitle("Review redactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationTask == nil
                                ? "Cancel"
                                : operationStopRequested
                                    ? "Stopping"
                                    : "Stop"
                        ).localizedUI
                    ) {
                        if operationTask != nil {
                            interruptRedaction()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(operationStopRequested)
                }
            }
        }
        .onAppear {
            sourceContentRevisionID = model.record(id: recordID)?
                .contentRevisionID
            refreshMarkGroups()
        }
        .onChange(of: marks) {
            markFeedback += 1
            if !sourceWasUpdated {
                operationErrorMessage = nil
            }
            refreshMarkGroups()
        }
        .onChange(
            of: model.record(id: recordID)?
                .contentRevisionID
        ) { oldRevisionID, newRevisionID in
            guard oldRevisionID != newRevisionID, newRevisionID != sourceContentRevisionID,
                  operationTask == nil else { return }
            interruptRedaction(invalidateResult: true)
            sourceContentRevisionID = newRevisionID
            sourceWasUpdated = true
            marks.removeAll(keepingCapacity: false)
            operationErrorMessage =
                "The PDF changed. Mark the updated pages again."
                    .localizedUI
            errorFeedback += 1
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptRedaction(invalidateResult: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptRedaction(invalidateResult: true)
        }
        .onDisappear {
            interruptRedaction(invalidateResult: true)
        }
        .alert(
            "Clear all marked areas?",
            isPresented: $isConfirmingClearMarks
        ) {
            Button("Clear Marks", role: .destructive) {
                marks.removeAll()
            }
            Button("Keep Marks", role: .cancel) {}
        } message: {
            Text("This only clears the review list. No PDF has been changed.")
        }
        .interactiveDismissDisabled(operationTask != nil)
        .sensoryFeedback(.selection, trigger: markFeedback)
        .sensoryFeedback(.error, trigger: errorFeedback)
    }

    private func refreshMarkGroups() {
        let cleaned = PDFRedactionMarkSanitizer.clean(marks)
        if cleaned != marks {
            marks = cleaned
        }
        let grouped = Dictionary(
            grouping: cleaned,
            by: \.pageIndex
        )
        pageGroups = grouped.keys.sorted().map {
            PageGroup(
                pageIndex: $0,
                marks: grouped[$0] ?? []
            )
        }
    }

    private func startRedaction() {
        guard operationTask == nil,
              let sourceContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == sourceContentRevisionID,
              !sourceWasUpdated,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        operationErrorMessage = nil
        operationStopRequested = false
        let generation = UUID()
        operationGeneration = generation
        let requestedMarks = marks
        operationTask = Task { @MainActor in
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createRedactedCopy(
                    recordID: recordID,
                    marks: requestedMarks,
                    expectedContentRevisionID:
                        sourceContentRevisionID
                )
            }
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            if let created { self.sourceContentRevisionID = created.contentRevisionID }
            operationTask = nil
            operationStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    created == nil
                        ? "Changes stopped"
                        : "Document saved before stopping"
                ).localizedUI
                return
            }
            guard let created else {
                if !Task.isCancelled {
                    operationErrorMessage =
                        "Redaction failed. The document and marked areas are unchanged."
                            .localizedUI
                    errorFeedback += 1
                }
                return
            }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private var redactionActionHint: String {
        if operationTask != nil {
            return "Wait for redaction to finish."
                .localizedUI
        }
        if marks.isEmpty {
            return "Mark at least one area before applying redaction."
                .localizedUI
        }
        return "Creates a separate PDF with the marked content permanently removed."
            .localizedUI
    }

    private func interruptRedaction(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            operationGeneration = UUID()
            operationStopRequested = false
        } else if operationTask != nil {
            guard !operationStopRequested else { return }
            operationStopRequested = true
        }
        operationTask?.cancel()
        if invalidateResult {
            operationTask = nil
            operationErrorMessage = nil
        }
    }
}

private struct BookletPreparationSheet: View {
    private enum ReviewMode:
        String,
        CaseIterable,
        Identifiable {
        case all
        case front
        case back

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .front: return "Front Side"
            case .back: return "Back Side"
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
    let onCreated: (DocumentRoute) -> Void

    private let defaultOptions: PDFBookletOptions

    @State private var options: PDFBookletOptions
    @State private var assessment: PDFBookletAssessment?
    @State private var reviewMode = ReviewMode.all
    @State private var assessmentTask: Task<Void, Never>?
    @State private var creationTask: Task<Void, Never>?
    @State private var assessmentGeneration = 0
    @State private var creationGeneration = UUID()
    @State private var creationStopRequested = false
    @State private var optionFeedback = 0
    @State private var successFeedback = 0
    @State private var errorFeedback = 0
    @State private var assessmentErrorMessage: String?
    @State private var creationErrorMessage: String?
    @State private var isConfirmingDiscard = false

    init(
        recordID: UUID,
        onCreated: @escaping (DocumentRoute) -> Void
    ) {
        let region = Locale.current.region?.identifier ?? ""
        let paperTarget: PDFPrintPaperTarget =
            ["US", "CA"].contains(region) ? .letter : .a4
        let defaults = PDFBookletOptions(
            paperTarget: paperTarget,
            bindingEdge: .left,
            outerMarginPoints: 24,
            gutterPoints: 12,
            showsFoldMarks: true,
            signatureSheetLimit: 0,
            creepCompensationPoints: 0
        )
        self.recordID = recordID
        self.onCreated = onCreated
        defaultOptions = defaults
        _options = State(initialValue: defaults)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: PPSpacing.medium) {
                        bookletHeader
                        bookletControls
                        duplexInstruction
                        spreadReview
                    }
                    .frame(maxWidth: 1_080)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }

                bottomCommand
            }
            .background(PPColor.canvas)
            .navigationTitle("Booklet Studio".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            creationStopRequested
                                ? "Stopping"
                                : creationTask != nil
                                    ? "Stop"
                                    : "Cancel"
                        ).localizedUI
                    ) {
                        if creationTask != nil {
                            stopWork()
                        } else {
                            requestDismissal()
                        }
                    }
                    .disabled(creationStopRequested)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reset".localizedUI) {
                        withAnimation(
                            reduceMotion
                                ? nil
                                : .easeOut(duration: 0.18)
                        ) {
                            options = defaultOptions
                            reviewMode = .all
                        }
                    }
                    .disabled(
                        creationTask != nil
                            || options == defaultOptions
                    )
                }
            }
        }
        .onAppear {
            startAssessment(debounced: false)
        }
        .onChange(of: options) { _, _ in
            optionFeedback += 1
            assessmentErrorMessage = nil
            creationErrorMessage = nil
            startAssessment(debounced: true)
        }
        .onChange(
            of: model.record(id: recordID)?
                .contentRevisionID
        ) { oldRevisionID, newRevisionID in
            guard oldRevisionID != newRevisionID else { return }
            interruptBookletWork()
            assessment = nil
            assessmentErrorMessage = nil
            creationErrorMessage = nil
            guard newRevisionID != nil,
                  scenePhase == .active,
                  UIApplication.shared
                    .isProtectedDataAvailable
            else { return }
            startAssessment(debounced: false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active,
               assessment == nil,
               assessmentTask == nil,
               creationTask == nil {
                startAssessment(debounced: false)
            } else if phase == .background {
                interruptBookletWork()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptBookletWork()
        }
        .onDisappear {
            interruptBookletWork()
        }
        .confirmationDialog(
            "Discard booklet setup?".localizedUI,
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(
                "Discard Setup".localizedUI,
                role: .destructive
            ) {
                dismiss()
            }
            Button("Keep Editing".localizedUI, role: .cancel) {}
        } message: {
            Text(
                "These booklet export options have not been applied."
                    .localizedUI
            )
        }
        .interactiveDismissDisabled(
            creationTask != nil || options != defaultOptions
        )
        .sensoryFeedback(.selection, trigger: optionFeedback)
        .sensoryFeedback(.success, trigger: successFeedback)
        .sensoryFeedback(.error, trigger: errorFeedback)
    }

    private var bookletHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "BOOKLET IMPOSITION",
            title: "Arrange pages for folding",
            symbol: "book.pages.fill",
            tint: PPColor.amber,
            metrics: [
                WorkflowMetric(
                    value:
                        "\(assessment?.sourcePageCount ?? 0)",
                    label: "Source",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: "\(assessment?.sheetCount ?? 0)",
                    label: "Sheets",
                    symbol: "rectangle.stack",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.insertedBlankCount ?? 0)",
                    label: "Blanks",
                    symbol: "rectangle",
                    tint:
                        (assessment?.insertedBlankCount ?? 0) == 0
                            ? PPColor.mint
                            : PPColor.amber
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.signatureCount ?? 1)",
                    label: "Sigs",
                    symbol: "square.stack.3d.up",
                    tint: (assessment?.signatureCount ?? 1) > 1
                        ? PPColor.amber
                        : PPColor.mint
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.maximumCreepOffsetPoints ?? 0) pt",
                    label: "Creep",
                    symbol: "arrow.left.and.right",
                    tint: (assessment?.maximumCreepOffsetPoints ?? 0) > 0
                        ? PPColor.cyan
                        : PPColor.textSecondary
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.averageScalePercent ?? 100)%",
                    label: "Avg Scale",
                    symbol: "arrow.down.right.and.arrow.up.left",
                    tint: PPColor.cyan
                )
            ]
        )
    }

    private var bookletControls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(
                    alignment: .bottom,
                    spacing: PPSpacing.large
                ) {
                    paperControl
                    bindingControl
                }
                VStack(alignment: .leading, spacing: PPSpacing.medium) {
                    paperControl
                    bindingControl
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(
                    alignment: .bottom,
                    spacing: PPSpacing.large
                ) {
                    outerMarginControl
                    gutterControl
                }
                VStack(alignment: .leading, spacing: PPSpacing.medium) {
                    outerMarginControl
                    gutterControl
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(
                    alignment: .bottom,
                    spacing: PPSpacing.large
                ) {
                    signatureControl
                    creepControl
                }
                VStack(alignment: .leading, spacing: PPSpacing.medium) {
                    signatureControl
                    creepControl
                }
            }

            Toggle(isOn: $options.showsFoldMarks) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fold marks".localizedUI)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Text(
                            "Add short vector marks at the top and bottom center."
                                .localizedUI
                        )
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                    }
                } icon: {
                    Image(systemName: "scissors")
                        .foregroundStyle(PPColor.amber)
                }
            }
            .tint(PPColor.amber)
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, PPSpacing.medium)
        .background(PPColor.surface.opacity(0.62))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .disabled(creationTask != nil)
    }

    private var paperControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "SHEET")
            let picker = Picker(
                "Sheet",
                selection: $options.paperTarget
            ) {
                ForEach(
                    [
                        PDFPrintPaperTarget.a4,
                        .letter,
                        .legal
                    ]
                ) { target in
                    Text(target.title.localizedUI).tag(target)
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
        .frame(
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout ? nil : 260,
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private var bindingControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "BINDING")
            let picker = Picker(
                "Binding",
                selection: $options.bindingEdge
            ) {
                ForEach(PDFBookletBindingEdge.allCases) { edge in
                    Text(edge.title.localizedUI).tag(edge)
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
        .frame(
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout ? nil : 260,
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private var signatureControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: PPSpacing.small) {
                SectionEyebrow(text: "SIGNATURES")
                if let assessment,
                   assessment.options == options {
                    Text(
                        AppLocalization.format(
                            "%lld × max %lld sheets",
                            assessment.signatureCount,
                            max(1, assessment.largestSignatureSheetCount)
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                }
            }
            let picker = Picker(
                "Signature",
                selection: $options.signatureSheetLimit
            ) {
                Text("All pages".localizedUI).tag(0)
                Text("4 sheets".localizedUI).tag(4)
                Text("8 sheets".localizedUI).tag(8)
                Text("12 sheets".localizedUI).tag(12)
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
        .frame(
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout ? nil : 280,
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private var creepControl: some View {
        bookletSlider(
            eyebrow: "CREEP COMP",
            value: $options.creepCompensationPoints,
            range: 0...18,
            step: 1
        )
    }

    private var outerMarginControl: some View {
        bookletSlider(
            eyebrow: "OUTER MARGIN",
            value: $options.outerMarginPoints,
            range: 12...72,
            step: 6
        )
    }

    private var gutterControl: some View {
        bookletSlider(
            eyebrow: "GUTTER",
            value: $options.gutterPoints,
            range: 0...48,
            step: 4
        )
    }

    private func bookletSlider(
        eyebrow: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionEyebrow(text: eyebrow)
                Spacer()
                Text(
                    AppLocalization.format(
                        "%lld pt",
                        Int(value.wrappedValue.rounded())
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(PPColor.cyan)
            }
            Slider(value: value, in: range, step: step)
                .tint(PPColor.cyan)
        }
        .frame(minWidth: 240)
    }

    private var duplexInstruction: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.large) {
                instruction(
                    index: 1,
                    title: "Print duplex",
                    detail: "Flip on short edge"
                )
                instruction(
                    index: 2,
                    title: "Keep stack order",
                    detail: "Front then back"
                )
                instruction(
                    index: 3,
                    title: "Fold at center",
                    detail: options.bindingEdge.title
                )
                instruction(
                    index: 4,
                    title: "Trim after fold",
                    detail: options.creepCompensationPoints > 0
                        ? "Creep compensated"
                        : "No creep shift"
                )
            }
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                instruction(
                    index: 1,
                    title: "Print duplex",
                    detail: "Flip on short edge"
                )
                instruction(
                    index: 2,
                    title: "Keep stack order",
                    detail: "Front then back"
                )
                instruction(
                    index: 3,
                    title: "Fold at center",
                    detail: options.bindingEdge.title
                )
                instruction(
                    index: 4,
                    title: "Trim after fold",
                    detail: options.creepCompensationPoints > 0
                        ? "Creep compensated"
                        : "No creep shift"
                )
            }
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, 7)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PPColor.amber)
                .frame(width: 2)
        }
    }

    private func instruction(
        index: Int,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Text("\(index)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(PPColor.canvas)
                .frame(width: 19, height: 19)
                .background(PPColor.amber)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(title.localizedUI)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? 2
                            : 1
                    )
                Text(detail.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? 3
                            : 1
                    )
            }
        }
    }

    private var spreadReview: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(
                    alignment: .center,
                    spacing: PPSpacing.medium
                ) {
                    reviewHeader
                    Spacer(minLength: PPSpacing.small)
                    reviewPicker
                        .frame(maxWidth: 300)
                }
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    reviewHeader
                    reviewPicker
                }
            }

            if let assessment,
               assessment.options == options {
                LazyVGrid(
                    columns: spreadColumns,
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    ForEach(filteredSpreads) { spread in
                        spreadRow(spread)
                    }
                }
            } else if assessmentTask != nil {
                HStack(spacing: PPSpacing.medium) {
                    ProgressView()
                    Text("Calculating booklet order".localizedUI)
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, PPSpacing.xLarge)
            } else {
                VStack(spacing: PPSpacing.medium) {
                    PPEmptyState(
                        kind: .workspace,
                        title: "Booklet evidence unavailable",
                        message: assessmentErrorMessage
                            ?? "Reset or change an option to recalculate."
                                .localizedUI
                    )
                    Button {
                        startAssessment(debounced: false)
                    } label: {
                        Label(
                            "Retry Booklet Assessment",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
                }
                .padding(.vertical, PPSpacing.xLarge)
            }
        }
    }

    private var reviewHeader: some View {
        WorkflowSectionHeader(
            eyebrow: "IMPOSED SIDES",
            title: "Front and back order",
            count: filteredSpreads.count,
            tint: PPColor.amber
        )
    }

    @ViewBuilder
    private var reviewPicker: some View {
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
            picker.pickerStyle(.segmented)
        }
    }

    private var spreadColumns: [GridItem] {
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

    private func spreadRow(
        _ spread: PDFBookletSpread
    ) -> some View {
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
            BookletSpreadDiagram(spread: spread)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: PPSpacing.small) {
                    Text(
                        AppLocalization.format(
                            "Sig %lld · Sheet %lld",
                            spread.signatureNumber,
                            spread.sheetNumber
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textPrimary)
                    Text(spread.side.title.localizedUI.uppercased())
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(
                            spread.side == .front
                                ? PPColor.cyan
                                : PPColor.amber
                        )
                }
                Text(spreadOrderLabel(spread))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PPColor.textPrimary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.large) {
                        spreadEvidence(spread)
                    }
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xSmall
                    ) {
                        spreadEvidence(spread)
                    }
                }
            }

            if !dynamicTypeSize.ppPrefersExpandedLayout {
                Spacer(minLength: PPSpacing.small)
            }

            if spread.hasBlankSlot {
                Image(systemName: "rectangle.dashed")
                    .font(.subheadline)
                    .foregroundStyle(PPColor.amber)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(PPColor.mint)
            }
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, 7)
        .background(PPColor.surface.opacity(0.62))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(
                    spread.hasBlankSlot
                        ? PPColor.amber.opacity(0.55)
                        : PPColor.border.opacity(0.62)
                )
                .frame(height: spread.hasBlankSlot ? 1 : 0.6)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func spreadEvidence(
        _ spread: PDFBookletSpread
    ) -> some View {
        slotEvidence(spread.left, label: "left")
        slotEvidence(spread.right, label: "right")
        if spread.left.creepOffsetPoints != 0
            || spread.right.creepOffsetPoints != 0 {
            evidence(
                AppLocalization.format(
                    "%.0f pt",
                    max(
                        abs(spread.left.creepOffsetPoints),
                        abs(spread.right.creepOffsetPoints)
                    )
                ),
                label: "creep"
            )
        }
    }

    private func slotEvidence(
        _ slot: PDFBookletSlot,
        label: String
    ) -> some View {
        evidence(
            slot.isBlank
                ? "Blank".localizedUI
                : AppLocalization.format(
                    "Page %lld · %lld%%",
                    slot.pageNumber ?? 0,
                    slot.scalePercent
                ),
            label: label
        )
    }

    private func evidence(
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
        }
    }

    private func spreadOrderLabel(
        _ spread: PDFBookletSpread
    ) -> String {
        AppLocalization.format(
            "%@ · %@",
            spread.left.pageNumber.map(String.init)
                ?? "Blank".localizedUI,
            spread.right.pageNumber.map(String.init)
                ?? "Blank".localizedUI
        )
    }

    private var bottomCommand: some View {
        VStack(spacing: PPSpacing.small) {
            if creationTask != nil,
               let progress = model.progress(for: recordID) {
                LocalOperationProgressView(progress: progress)
            }
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.medium) {
                    outputContract
                    createButton
                        .frame(maxWidth: 420)
                }
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    outputContract
                    createButton
                }
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

    private var outputContract: some View {
        Label {
            Text(
                "Two-up PDF · signatures and creep visible · source unchanged"
                    .localizedUI
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .lineLimit(
                dynamicTypeSize.ppPrefersExpandedLayout ? nil : 1
            )
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(PPColor.mint)
        }
        .accessibilityElement(children: .combine)
    }

    private var createButton: some View {
        Button {
            createBooklet()
        } label: {
            Label(
                creationStopRequested
                    ? "Finishing current file commit".localizedUI
                    : creationTask == nil
                        ? "Export Booklet".localizedUI
                        : "Exporting Booklet".localizedUI,
                systemImage: creationTask == nil
                    ? "book.pages.fill"
                    : "hourglass"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            assessment == nil
                || assessment?.options != options
                || assessmentTask != nil
                || creationTask != nil
        )
        .keyboardShortcut(.defaultAction)
        .accessibilityHint(bookletCreationHint)
    }

    private var filteredSpreads: [PDFBookletSpread] {
        guard let assessment,
              assessment.options == options
        else { return [] }
        switch reviewMode {
        case .all:
            return assessment.spreads
        case .front:
            return assessment.spreads.filter { $0.side == .front }
        case .back:
            return assessment.spreads.filter { $0.side == .back }
        }
    }

    private var bookletCreationHint: String {
        if creationTask != nil {
            return "Wait for the booklet export to finish."
                .localizedUI
        }
        if assessmentTask != nil {
            return "Wait for booklet evidence to finish."
                .localizedUI
        }
        if assessment == nil || assessment?.options != options {
            return "Retry the check before exporting the booklet."
                .localizedUI
        }
        return "Creates a separate two-up booklet PDF."
            .localizedUI
    }

    private func startAssessment(
        debounced: Bool
    ) {
        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessmentTask?.cancel()
        assessmentErrorMessage = nil
        let requestedOptions = options
        assessmentTask = Task {
            if debounced {
                try? await Task.sleep(for: .milliseconds(140))
            }
            guard !Task.isCancelled else {
                if generation == assessmentGeneration {
                    assessmentTask = nil
                }
                return
            }
            let loaded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.bookletAssessment(
                    recordID: recordID,
                    options: requestedOptions
                )
            }
            guard !Task.isCancelled,
                  generation == assessmentGeneration,
                  options == requestedOptions
            else {
                if generation == assessmentGeneration {
                    assessmentTask = nil
                }
                return
            }
            guard let loaded else {
                assessment = nil
                assessmentTask = nil
                assessmentErrorMessage =
                    "Booklet evidence could not be calculated. Try again."
                        .localizedUI
                errorFeedback += 1
                return
            }
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.16)
            ) {
                assessment = loaded
                assessmentTask = nil
            }
        }
    }

    private func createBooklet() {
        guard scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        guard let assessment,
              assessment.options == options,
              model.record(id: recordID)?.contentRevisionID
                == assessment.revisionID
        else {
            startAssessment(debounced: false)
            return
        }
        let requestedOptions = options
        creationErrorMessage = nil
        creationStopRequested = false
        let generation = UUID()
        creationGeneration = generation
        creationTask = Task { @MainActor in
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createBookletCopy(
                    recordID: recordID,
                    options: requestedOptions,
                    expectedContentRevisionID:
                        assessment.revisionID
                )
            }
            guard creationGeneration == generation else { return }
            let wasStopped =
                creationStopRequested || Task.isCancelled
            creationTask = nil
            creationStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    created == nil
                        ? "Changes stopped"
                        : "Document saved before stopping"
                ).localizedUI
                return
            }
            guard let created else {
                if !Task.isCancelled {
                    creationErrorMessage =
                        "The booklet export failed. Your document and options are unchanged."
                            .localizedUI
                    errorFeedback += 1
                }
                return
            }
            successFeedback += 1
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func stopWork() {
        guard creationTask != nil,
              !creationStopRequested
        else { return }
        creationStopRequested = true
        creationTask?.cancel()
    }

    private func requestDismissal() {
        if options != defaultOptions {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func interruptBookletWork() {
        assessmentGeneration += 1
        creationGeneration = UUID()
        creationStopRequested = false
        assessmentTask?.cancel()
        assessmentTask = nil
        creationTask?.cancel()
        creationTask = nil
    }
}

private struct BookletSpreadDiagram: View {
    let spread: PDFBookletSpread

    var body: some View {
        HStack(spacing: 0) {
            slot(spread.left)
            Rectangle()
                .fill(PPColor.amber.opacity(0.72))
                .frame(width: 1)
                .overlay {
                    Rectangle()
                        .stroke(
                            PPColor.amber.opacity(0.62),
                            style: StrokeStyle(
                                lineWidth: 0.6,
                                dash: [2, 2]
                            )
                        )
                }
            slot(spread.right)
        }
        .frame(width: 90, height: 58)
        .background(PPColor.elevated)
        .clipShape(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(PPColor.border, lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    private func slot(
        _ slot: PDFBookletSlot
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(
                    slot.isBlank
                        ? PPColor.amber.opacity(0.08)
                        : PPColor.cyan.opacity(0.09)
                )
            Text(
                slot.pageNumber.map(String.init)
                    ?? "—"
            )
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(
                slot.isBlank ? PPColor.amber : PPColor.textPrimary
            )
            .offset(
                x: min(
                    5,
                    max(-5, CGFloat(slot.creepOffsetPoints) * 0.65)
                )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PrintPreparationSheet: View {
    private enum ReviewMode:
        String,
        CaseIterable,
        Identifiable {
        case all
        case preflight
        case bleed
        case safeArea
        case clipped
        case scaled

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .preflight: return "Preflight"
            case .bleed: return "Bleed"
            case .safeArea: return "Safe Area"
            case .clipped: return "Clipped"
            case .scaled: return "Scaled"
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
    let onCreated: (DocumentRoute) -> Void

    private let defaultOptions: PDFPrintPreparationOptions

    @State private var options: PDFPrintPreparationOptions
    @State private var assessment: PDFPrintPreparationAssessment?
    @State private var reviewMode = ReviewMode.all
    @State private var assessmentTask: Task<Void, Never>?
    @State private var creationTask: Task<Void, Never>?
    @State private var assessmentGeneration = 0
    @State private var creationGeneration = UUID()
    @State private var creationStopRequested = false
    @State private var optionFeedback = 0
    @State private var successFeedback = 0
    @State private var errorFeedback = 0
    @State private var assessmentErrorMessage: String?
    @State private var creationErrorMessage: String?
    @State private var isConfirmingDiscard = false

    init(
        recordID: UUID,
        onCreated: @escaping (DocumentRoute) -> Void
    ) {
        let region = Locale.current.region?.identifier ?? ""
        let paperTarget: PDFPrintPaperTarget =
            ["US", "CA"].contains(region) ? .letter : .a4
        let defaults = PDFPrintPreparationOptions(
            paperTarget: paperTarget,
            orientation: .automatic,
            scaleMode: .fit,
            marginPoints: 24
        )
        self.recordID = recordID
        self.onCreated = onCreated
        defaultOptions = defaults
        _options = State(initialValue: defaults)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: PPSpacing.medium) {
                        printHeader
                        printControls
                        productionPreflightStrip
                        consequenceStrip
                        pageReview
                    }
                    .frame(maxWidth: 1_080)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }

                bottomCommand
            }
            .background(PPColor.canvas)
            .navigationTitle("Print Preparation".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            creationStopRequested
                                ? "Stopping"
                                : creationTask != nil
                                    ? "Stop"
                                    : "Cancel"
                        ).localizedUI
                    ) {
                        if creationTask != nil {
                            stopWork()
                        } else {
                            requestDismissal()
                        }
                    }
                    .disabled(creationStopRequested)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reset".localizedUI) {
                        withAnimation(
                            reduceMotion
                                ? nil
                                : .easeOut(duration: 0.18)
                        ) {
                            options = defaultOptions
                            reviewMode = .all
                        }
                    }
                    .disabled(
                        creationTask != nil
                            || options == defaultOptions
                    )
                }
            }
        }
        .onAppear {
            startAssessment(debounced: false)
        }
        .onChange(of: options) { _, _ in
            optionFeedback += 1
            assessmentErrorMessage = nil
            creationErrorMessage = nil
            startAssessment(debounced: true)
        }
        .onChange(
            of: model.record(id: recordID)?
                .contentRevisionID
        ) { oldRevisionID, newRevisionID in
            guard oldRevisionID != newRevisionID else { return }
            interruptPrintPreparationWork()
            assessment = nil
            assessmentErrorMessage = nil
            creationErrorMessage = nil
            guard newRevisionID != nil,
                  scenePhase == .active,
                  UIApplication.shared
                    .isProtectedDataAvailable
            else { return }
            startAssessment(debounced: false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active,
               assessment == nil,
               assessmentTask == nil,
               creationTask == nil {
                startAssessment(debounced: false)
            } else if phase == .background {
                interruptPrintPreparationWork()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptPrintPreparationWork()
        }
        .onDisappear {
            interruptPrintPreparationWork()
        }
        .confirmationDialog(
            "Discard print setup?".localizedUI,
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(
                "Discard Setup".localizedUI,
                role: .destructive
            ) {
                dismiss()
            }
            Button("Keep Editing".localizedUI, role: .cancel) {}
        } message: {
            Text(
                "These print export options have not been applied."
                    .localizedUI
            )
        }
        .interactiveDismissDisabled(
            creationTask != nil || options != defaultOptions
        )
        .sensoryFeedback(.selection, trigger: optionFeedback)
        .sensoryFeedback(.success, trigger: successFeedback)
        .sensoryFeedback(.error, trigger: errorFeedback)
    }

    private var printHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "PRINT PREPARATION",
            title: "Prepare a print export",
            symbol: "printer.fill",
            tint: PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(assessment?.pages.count ?? 0)",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.clippedPageCount ?? 0)",
                    label: "Clipped",
                    symbol: "rectangle.badge.minus",
                    tint: assessment?.clippedPageCount == 0
                        ? PPColor.mint
                        : PPColor.amber
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.productionReviewPageCount ?? 0)",
                    label: "Review",
                    symbol: "exclamationmark.triangle",
                    tint:
                        (assessment?.productionReviewPageCount ?? 0) == 0
                            ? PPColor.mint
                            : PPColor.amber
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.bleedRiskPageCount ?? 0)",
                    label: "Bleed",
                    symbol: "scissors",
                    tint:
                        (assessment?.bleedRiskPageCount ?? 0) == 0
                            ? PPColor.mint
                            : PPColor.amber
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.safeAreaRiskPageCount ?? 0)",
                    label: "Safe",
                    symbol: "rectangle.inset.filled",
                    tint:
                        (assessment?.safeAreaRiskPageCount ?? 0) == 0
                            ? PPColor.mint
                            : PPColor.amber
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.averageScalePercent ?? 100)%",
                    label: "Avg Scale",
                    symbol: "arrow.up.left.and.arrow.down.right",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.annotationCount ?? 0)",
                    label: "Baked In",
                    symbol: "pencil.and.outline",
                    tint: PPColor.mint
                )
            ]
        )
    }

    private var printControls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(
                    alignment: .bottom,
                    spacing: PPSpacing.large
                ) {
                    paperTargetControl
                    orientationControl
                }
                VStack(alignment: .leading, spacing: PPSpacing.medium) {
                    paperTargetControl
                    orientationControl
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(
                    alignment: .bottom,
                    spacing: PPSpacing.large
                ) {
                    scaleModeControl
                    marginControl
                }
                VStack(alignment: .leading, spacing: PPSpacing.medium) {
                    scaleModeControl
                    marginControl
                }
            }
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, PPSpacing.medium)
        .background(PPColor.surface.opacity(0.62))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .disabled(creationTask != nil)
    }

    private var paperTargetControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "PAPER")
            let picker = Picker(
                "Paper",
                selection: $options.paperTarget
            ) {
                ForEach(PDFPrintPaperTarget.allCases) { target in
                    Text(target.title.localizedUI).tag(target)
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
        .frame(
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout ? nil : 280,
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private var orientationControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "ORIENTATION")
            let picker = Picker(
                "Orientation",
                selection: $options.orientation
            ) {
                ForEach(
                    PDFPrintOrientationPolicy.allCases
                ) { orientation in
                    Text(orientation.title.localizedUI)
                        .tag(orientation)
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
                    .disabled(options.paperTarget == .original)
            } else {
                picker
                    .pickerStyle(.segmented)
                    .disabled(options.paperTarget == .original)
            }
        }
        .frame(
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout ? nil : 260,
            maxWidth: .infinity,
            alignment: .leading
        )
        .opacity(options.paperTarget == .original ? 0.58 : 1)
    }

    private var scaleModeControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "PLACEMENT")
            let picker = Picker(
                "Placement",
                selection: $options.scaleMode
            ) {
                ForEach(PDFPrintScaleMode.allCases) { mode in
                    Label(
                        mode.title.localizedUI,
                        systemImage: mode.symbol
                    )
                    .tag(mode)
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
        .frame(
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout ? nil : 280,
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private var marginControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionEyebrow(text: "PRINTABLE MARGIN")
                Spacer()
                Text(
                    AppLocalization.format(
                        "%lld pt",
                        Int(options.marginPoints.rounded())
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(PPColor.cyan)
            }
            Slider(
                value: $options.marginPoints,
                in: 0...72,
                step: 6
            )
            .tint(PPColor.cyan)
        }
        .frame(minWidth: 240)
    }

    private var productionPreflightStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.medium) {
                productionToken(
                    title: "TRIM",
                    value: trimSummary,
                    risk: assessment?.productionReviewPageCount ?? 0
                )
                productionToken(
                    title: "BLEED",
                    value: bleedSummary,
                    risk: assessment?.bleedRiskPageCount ?? 0
                )
                productionToken(
                    title: "SAFE AREA",
                    value: safeAreaSummary,
                    risk: assessment?.safeAreaRiskPageCount ?? 0
                )
                Spacer(minLength: PPSpacing.small)
            }
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                productionToken(
                    title: "TRIM",
                    value: trimSummary,
                    risk: assessment?.productionReviewPageCount ?? 0
                )
                productionToken(
                    title: "BLEED",
                    value: bleedSummary,
                    risk: assessment?.bleedRiskPageCount ?? 0
                )
                productionToken(
                    title: "SAFE AREA",
                    value: safeAreaSummary,
                    risk: assessment?.safeAreaRiskPageCount ?? 0
                )
            }
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, 7)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(
                    (assessment?.productionRiskPageCount ?? 0) > 0
                        || (assessment?.productionCautionPageCount ?? 0) > 0
                        ? PPColor.amber
                        : PPColor.mint
                )
                .frame(width: 2)
        }
    }

    private func productionToken(
        title: String,
        value: String,
        risk: Int
    ) -> some View {
        HStack(spacing: 6) {
            Image(
                systemName: risk == 0
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.caption2.weight(.bold))
            .foregroundStyle(risk == 0 ? PPColor.mint : PPColor.amber)
            VStack(alignment: .leading, spacing: 0) {
                Text(title.localizedUI)
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                Text(value.localizedUI)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
            }
        }
    }

    private var trimSummary: String {
        guard let assessment else { return "Pending".localizedUI }
        return AppLocalization.format(
            "%lld review / %lld pages",
            assessment.productionReviewPageCount,
            assessment.pages.count
        )
    }

    private var bleedSummary: String {
        guard let assessment else { return "Pending".localizedUI }
        return AppLocalization.format(
            "%lld need review",
            assessment.bleedRiskPageCount
        )
    }

    private var safeAreaSummary: String {
        guard let assessment else { return "Pending".localizedUI }
        return AppLocalization.format(
            "%lld near trim",
            assessment.safeAreaRiskPageCount
        )
    }

    private var consequenceStrip: some View {
        HStack(spacing: PPSpacing.medium) {
            Image(systemName: options.scaleMode.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(consequenceColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(consequenceTitle.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(consequenceDetail.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: PPSpacing.small)
            if assessmentTask != nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("VECTOR".localizedUI)
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.mint)
            }
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, 7)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(consequenceColor)
                .frame(width: 2)
        }
    }

    private var consequenceTitle: String {
        switch options.scaleMode {
        case .fit:
            return "Keep every page edge"
        case .fill:
            return "Fill the printable area"
        case .actual:
            return "Keep physical content size"
        }
    }

    private var consequenceDetail: String {
        switch options.scaleMode {
        case .fit:
            return "Pages may gain whitespace or scale down, but content stays visible."
        case .fill:
            return "Pages fill the printable frame; highlighted pages lose outer content."
        case .actual:
            return "Oversized pages are clipped at 100% scale."
        }
    }

    private var consequenceColor: Color {
        (assessment?.clippedPageCount ?? 0) > 0
            ? PPColor.amber
            : PPColor.cyan
    }

    private var pageReview: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(
                    alignment: .center,
                    spacing: PPSpacing.medium
                ) {
                    reviewSectionHeader
                    Spacer(minLength: PPSpacing.small)
                    reviewPicker
                        .frame(maxWidth: 320)
                }
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    reviewSectionHeader
                    reviewPicker
                }
            }

            if let assessment,
               assessment.options == options {
                if filteredPages.isEmpty {
                    PPEmptyState(
                        kind: .workspace,
                        title: "No pages in this review",
                        message:
                            "Choose All to inspect every print consequence."
                    )
                    .padding(.vertical, PPSpacing.xLarge)
                } else {
                    LazyVGrid(
                        columns: pageColumns,
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        ForEach(filteredPages) { page in
                            printPageRow(page)
                        }
                    }
                }
            } else if assessmentTask != nil {
                HStack(spacing: PPSpacing.medium) {
                    ProgressView()
                    Text("Calculating print geometry".localizedUI)
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, PPSpacing.xLarge)
            } else {
                VStack(spacing: PPSpacing.medium) {
                    PPEmptyState(
                        kind: .workspace,
                        title: "Print evidence unavailable",
                        message: assessmentErrorMessage
                            ?? "Reset or change a print option to recalculate."
                                .localizedUI
                    )
                    Button {
                        startAssessment(debounced: false)
                    } label: {
                        Label(
                            "Retry Print Assessment",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
                }
                .padding(.vertical, PPSpacing.xLarge)
            }
        }
    }

    private var reviewSectionHeader: some View {
        WorkflowSectionHeader(
            eyebrow: "PAGE EVIDENCE",
            title: "Output consequences",
            count: filteredPages.count,
            tint: PPColor.cyan
        )
    }

    @ViewBuilder
    private var reviewPicker: some View {
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
            picker.pickerStyle(.segmented)
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

    private func printPageRow(
        _ page: PDFPrintPreparationPage
    ) -> some View {
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
            PrintPageGeometryDiagram(page: page)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: PPSpacing.small) {
                    Text(
                        AppLocalization.format(
                            "Page %lld",
                            page.pageIndex + 1
                        )
                    )
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textPrimary)
                    Text(page.outcomeTitle.localizedUI.uppercased())
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(outcomeColor(page))
                }
                Text(
                    "\(page.sourceSizeLabel) → \(page.outputSizeLabel)"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? 2
                        : 1
                )
                let evidenceLayout =
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? AnyLayout(
                            VStackLayout(
                                alignment: .leading,
                                spacing: PPSpacing.xSmall
                            )
                        )
                        : AnyLayout(
                            HStackLayout(spacing: PPSpacing.large)
                        )
                evidenceLayout {
                    printPlacementEvidence(page)
                }
                evidenceLayout {
                    printProductionEvidence(page)
                }
            }

            if !dynamicTypeSize.ppPrefersExpandedLayout {
                Spacer(minLength: PPSpacing.small)
            }

            Image(
                systemName: page.hasClipping
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(outcomeColor(page))
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, 7)
        .background(PPColor.surface.opacity(0.62))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(
                    page.hasClipping
                        ? PPColor.amber.opacity(0.55)
                        : PPColor.border.opacity(0.62)
                )
                .frame(height: page.hasClipping ? 1 : 0.6)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func printPlacementEvidence(
        _ page: PDFPrintPreparationPage
    ) -> some View {
        evidence(
            "\(page.scalePercent)%",
            label: "scale"
        )
        evidence(
            "\(page.visiblePercent)%",
            label: "visible"
        )
        evidence(
            page.hasPadding ? "Yes" : "No",
            label: "padding"
        )
    }

    @ViewBuilder
    private func printProductionEvidence(
        _ page: PDFPrintPreparationPage
    ) -> some View {
        evidence(
            page.productionEvidence.trimSummary,
            label: "trim",
            tint: riskColor(
                page.productionEvidence.overallRisk
            )
        )
        evidence(
            page.productionEvidence.bleedSummary,
            label: "bleed",
            tint: riskColor(
                page.productionEvidence.bleedRisk
            )
        )
        evidence(
            page.productionEvidence.safeAreaSummary,
            label: "safe",
            tint: riskColor(
                page.productionEvidence.safeAreaRisk
            )
        )
    }

    private func evidence(
        _ value: String,
        label: String,
        tint: Color = PPColor.textPrimary
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.localizedUI)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(label.localizedUI)
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
        }
    }

    private func outcomeColor(
        _ page: PDFPrintPreparationPage
    ) -> Color {
        if page.productionEvidence.overallRisk != .clear {
            return riskColor(page.productionEvidence.overallRisk)
        }
        if page.hasClipping {
            return PPColor.amber
        }
        if page.isScaled {
            return PPColor.cyan
        }
        return PPColor.mint
    }

    private func riskColor(
        _ risk: PDFPrintProductionRisk
    ) -> Color {
        switch risk {
        case .clear:
            return PPColor.mint
        case .caution:
            return PPColor.cyan
        case .risk:
            return PPColor.amber
        }
    }

    private var bottomCommand: some View {
        VStack(spacing: PPSpacing.small) {
            if creationTask != nil,
               let progress = model.progress(for: recordID) {
                LocalOperationProgressView(progress: progress)
            }
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.medium) {
                    outputContract
                    createButton
                        .frame(maxWidth: 420)
                }
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    outputContract
                    createButton
                }
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

    private var outputContract: some View {
        Label {
            Text(
                "Print export · annotations included · current document unchanged"
                    .localizedUI
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .lineLimit(
                dynamicTypeSize.ppPrefersExpandedLayout ? nil : 1
            )
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(PPColor.mint)
        }
        .accessibilityElement(children: .combine)
    }

    private var createButton: some View {
        Button {
            createPrintReadyCopy()
        } label: {
            Label(
                creationStopRequested
                    ? "Finishing current file commit".localizedUI
                    : creationTask == nil
                        ? "Export for Printing".localizedUI
                        : "Preparing Print Export".localizedUI,
                systemImage: creationTask == nil
                    ? "printer.fill"
                    : "hourglass"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            assessment == nil
                || assessment?.options != options
                || assessmentTask != nil
                || creationTask != nil
        )
        .keyboardShortcut(.defaultAction)
        .accessibilityHint(printCreationHint)
    }

    private var filteredPages: [PDFPrintPreparationPage] {
        guard let assessment,
              assessment.options == options
        else { return [] }
        switch reviewMode {
        case .all:
            return assessment.pages
        case .preflight:
            return assessment.pages.filter {
                $0.productionEvidence.overallRisk != .clear
            }
        case .bleed:
            return assessment.pages.filter {
                $0.productionEvidence.bleedRisk != .clear
            }
        case .safeArea:
            return assessment.pages.filter {
                $0.productionEvidence.safeAreaRisk != .clear
            }
        case .clipped:
            return assessment.pages.filter(\.hasClipping)
        case .scaled:
            return assessment.pages.filter(\.isScaled)
        }
    }

    private var printCreationHint: String {
        if creationTask != nil {
            return "Wait for the print export to finish."
                .localizedUI
        }
        if assessmentTask != nil {
            return "Wait for print evidence to finish."
                .localizedUI
        }
        if assessment == nil || assessment?.options != options {
            return "Retry the check before exporting for print."
                .localizedUI
        }
        return "Creates a separate print-ready PDF."
            .localizedUI
    }

    private func startAssessment(
        debounced: Bool
    ) {
        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessmentTask?.cancel()
        assessmentErrorMessage = nil
        let requestedOptions = options
        assessmentTask = Task {
            if debounced {
                try? await Task.sleep(for: .milliseconds(140))
            }
            guard !Task.isCancelled else {
                if generation == assessmentGeneration {
                    assessmentTask = nil
                }
                return
            }
            let loaded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.printPreparationAssessment(
                    recordID: recordID,
                    options: requestedOptions
                )
            }
            guard !Task.isCancelled,
                  generation == assessmentGeneration,
                  options == requestedOptions
            else {
                if generation == assessmentGeneration {
                    assessmentTask = nil
                }
                return
            }
            guard let loaded else {
                assessment = nil
                assessmentTask = nil
                assessmentErrorMessage =
                    "Print evidence could not be calculated. Try again."
                        .localizedUI
                errorFeedback += 1
                return
            }
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.16)
            ) {
                assessment = loaded
                assessmentTask = nil
            }
        }
    }

    private func createPrintReadyCopy() {
        guard scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        guard let assessment,
              assessment.options == options,
              model.record(id: recordID)?.contentRevisionID
                == assessment.revisionID
        else {
            startAssessment(debounced: false)
            return
        }
        let requestedOptions = options
        creationErrorMessage = nil
        creationStopRequested = false
        let generation = UUID()
        creationGeneration = generation
        creationTask = Task { @MainActor in
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createPrintReadyCopy(
                    recordID: recordID,
                    options: requestedOptions,
                    expectedContentRevisionID:
                        assessment.revisionID
                )
            }
            guard creationGeneration == generation else { return }
            let wasStopped =
                creationStopRequested || Task.isCancelled
            creationTask = nil
            creationStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    created == nil
                        ? "Changes stopped"
                        : "Document saved before stopping"
                ).localizedUI
                return
            }
            guard let created else {
                if !Task.isCancelled {
                    creationErrorMessage =
                        "The print export failed. Your document and options are unchanged."
                            .localizedUI
                    errorFeedback += 1
                }
                return
            }
            successFeedback += 1
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func stopWork() {
        guard creationTask != nil,
              !creationStopRequested
        else { return }
        creationStopRequested = true
        creationTask?.cancel()
    }

    private func requestDismissal() {
        if options != defaultOptions {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func interruptPrintPreparationWork() {
        assessmentGeneration += 1
        creationGeneration = UUID()
        creationStopRequested = false
        assessmentTask?.cancel()
        assessmentTask = nil
        creationTask?.cancel()
        creationTask = nil
    }
}

private struct PrintPageGeometryDiagram: View {
    let page: PDFPrintPreparationPage

    var body: some View {
        GeometryReader { proxy in
            let pageScale = min(
                proxy.size.width / page.outputWidth,
                proxy.size.height / page.outputHeight
            )
            let pageSize = CGSize(
                width: page.outputWidth * pageScale,
                height: page.outputHeight * pageScale
            )
            let printableSize = CGSize(
                width: page.printableWidth * pageScale,
                height: page.printableHeight * pageScale
            )
            let renderedSize = CGSize(
                width: page.renderedWidth * pageScale,
                height: page.renderedHeight * pageScale
            )

            ZStack {
                RoundedRectangle(
                    cornerRadius: 3,
                    style: .continuous
                )
                .fill(PPColor.elevated)
                .frame(
                    width: pageSize.width,
                    height: pageSize.height
                )
                .overlay {
                    ZStack {
                        Rectangle()
                            .fill(
                                page.hasClipping
                                    ? PPColor.amber.opacity(0.16)
                                    : PPColor.cyan.opacity(0.13)
                            )
                            .frame(
                                width: renderedSize.width,
                                height: renderedSize.height
                            )
                        Rectangle()
                            .stroke(
                                PPColor.cyan.opacity(0.72),
                                style: StrokeStyle(
                                    lineWidth: 0.8,
                                    dash: [2, 2]
                                )
                            )
                            .frame(
                                width: printableSize.width,
                                height: printableSize.height
                            )
                    }
                    .frame(
                        width: pageSize.width,
                        height: pageSize.height
                    )
                    .clipped()
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 3,
                        style: .continuous
                    )
                    .stroke(PPColor.border, lineWidth: 0.7)
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
        }
        .frame(width: 54, height: 68)
        .accessibilityHidden(true)
    }
}

private enum ExportCatalogMode:
    String,
    CaseIterable,
    Identifiable {
    case recommended
    case pdf
    case office
    case images

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: return "Recommended"
        case .pdf: return "PDF"
        case .office: return "Office"
        case .images: return "Images"
        }
    }
}

struct DocumentExportSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let initialFocus: PDFExportFocus?
    let initialOfficeReceiptID: UUID?
    let onCreated: (DocumentRoute) -> Void
    let onReviewPage: (Int, Bool) -> Void
    let onRepairPreflightItem:
        (PDFDeliveryPreflightRepairAction, Int?, Bool) -> Void
    @State private var activeFocus: PDFExportFocus?
    @State private var shareItems: [Any] = []
    @State private var preservesSharedTemporaryResult = false
    @State private var isSharing = false
    @State private var filesExportURL: URL?
    @State private var temporaryShareURLs: [URL] = []
    @State private var exportTask: Task<Void, Never>?
    @State private var exportGeneration = UUID()
    @State private var exportLabel: String?
    @State private var exportStopRequested = false
    @State private var pdfShareProgress: PDFOperationProgress?
    @State private var pdfShareRateWindow = ByteRateWindow()
    @State private var pdfShareGeneration = UUID()
    @State private var officeShareProgress: PDFOperationProgress?
    @State private var officeShareRateWindow = ByteRateWindow()
    @State private var officeShareGeneration = UUID()
    @State private var preflight: PDFDeliveryPreflightAssessment?
    @State private var preflightRevisionID: UUID?
    @State private var preflightError: String?
    @State private var preflightTask: Task<Void, Never>?
    @State private var preflightGeneration = UUID()
    @State private var preflightPaused = false
    @State private var preflightSuccessFeedback = 0
    @State private var preflightErrorFeedback = 0
    @State private var focusTransitionFeedback = 0
    @State private var preflightReviewTask: Task<Void, Never>?
    @State private var preflightReviewGeneration = UUID()
    @State private var openingPreflightItemID: String?
    @State private var preflightReviewErrorFeedback = 0
    @State private var deliveryPreviewPage = 0
    @State private var deliveryPageInput = ""
    @State private var showsDeliveryPagePicker = false
    @State private var isPreparingPrint = false
    @State private var isPreparingBooklet = false
    @State private var pendingPreparedRoute: DocumentRoute?
    @State private var transitioningPreparedRoute: DocumentRoute?
    @State private var preparedOutputTransitionTask:
        Task<Void, Never>?
    @State private var preparedOutputTransitionGeneration = UUID()
    @State private var preparedOutputTransitionFeedback = 0
    @State private var officeReceipt: PDFOfficeExportReceipt?
    @State private var activeOfficeFormat: PDFTextExportFormat?
    @State private var officeFailure: PDFOfficeExportFailure?
    @State private var officeRouteFeedback = 0
    @State private var officeReceiptFeedback = 0
    @State private var officeFailureFeedback = 0
    @State private var officePinFeedback = 0
    @State private var officeGovernanceTask: Task<Void, Never>?
    @State private var inspectedOfficeReceipt:
        PDFOfficeExportReceipt?
    @State private var selectedBatchRetrySegmentIDs: Set<UUID> = []
    @State private var isShowingAllOfficeBatchSegments = false
    @State private var showsOfficeEvidence = false
    @State private var selectedOfficeFormat: PDFTextExportFormat = .wordDocument
    @State private var didChooseOfficeFormat = false
    @State private var officePreviewPage = 0
    @State private var hasWideExportViewport = false
    @State private var temporaryOfficeResultURL: URL?
    @State private var officePreviewFile: OfficePreviewFile?
    @State private var officePreviewCopyURL: URL?
    @State private var officeResultNotice: String?
    @State private var isConfirmingTemporaryResultDiscard = false
    @State private var showsOfficeHistory = false
    @State private var usesOfficePageRange = false
    @State private var officeFirstPage = 1
    @State private var officeLastPage = 1
    @State private var officeHistoryQuery = ""
    @State private var officeHistoryFormat: PDFTextExportFormat?
    @State private var officeHistoryCurrentOnly = false
    @State private var didResolveInitialOfficeReceipt = false
    @AppStorage("privacy.hideLibraryPreviews")
    private var hideLibraryPreviews = false
    @State private var showsAdvancedPDFOptions = false
    @State private var showsPortableTextFormats = false
    @State private var selectedExportCatalogMode = ExportCatalogMode.pdf

    init(
        recordID: UUID,
        focus: PDFExportFocus? = nil,
        officeReceiptID: UUID? = nil,
        onCreated: @escaping (DocumentRoute) -> Void,
        onReviewPage: @escaping (Int, Bool) -> Void = { _, _ in },
        onRepairPreflightItem: @escaping (
            PDFDeliveryPreflightRepairAction,
            Int?,
            Bool
        ) -> Void = { _, _, _ in }
    ) {
        self.recordID = recordID
        self.initialFocus = focus
        self.initialOfficeReceiptID = officeReceiptID
        self.onCreated = onCreated
        self.onReviewPage = onReviewPage
        self.onRepairPreflightItem = onRepairPreflightItem
        self._activeFocus = State(initialValue: focus)
    }

    private var exportNavigation: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if model.record(id: recordID) == nil {
                    ContentUnavailableView(
                        "Document unavailable",
                        systemImage: "doc.questionmark",
                        description: Text(
                            "This private working copy is no longer available for export."
                        )
                    )
                } else {
                    exportWorkspace
                }
            }
            .navigationTitle(navigationTitle.localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if canReturnToExportCatalog {
                        Button {
                            returnToExportCatalog()
                        } label: {
                            Label(
                                "Formats",
                                systemImage: "chevron.backward"
                            )
                        }
                        .disabled(
                            exportTask != nil
                                || preflightReviewTask != nil
                                || isPreparedOutputTransitionActive
                                || temporaryOfficeResultURL != nil
                        )
                        .accessibilityHint(
                            "Returns to the output format list"
                                .localizedUI
                        )
                        .accessibilityIdentifier(
                            "returnToExportCatalog"
                        )
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if exportTask != nil {
                        Button(
                            (
                                exportStopRequested
                                    ? "Stopping"
                                    : "Stop"
                            ).localizedUI
                        ) {
                            stopExportPreparation()
                        }
                        .keyboardShortcut(.cancelAction)
                        .disabled(exportStopRequested)
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityIdentifier("officeExportStopAction")
                    } else if preflightReviewTask != nil {
                        Button("Stop".localizedUI) {
                            stopPreflightReviewHandoff()
                        }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(
                            "Stop opening issue action".localizedUI
                        )
                        .accessibilityIdentifier(
                            "preflightReviewStopAction"
                        )
                    } else if isPreparedOutputTransitionActive {
                        Button("Stay".localizedUI) {
                            cancelPreparedOutputTransition(
                                showsNotice: true
                            )
                        }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(
                            "Stay on this output sheet".localizedUI
                        )
                        .accessibilityHint(
                            "Keeps the export in export history and stops automatic opening."
                                .localizedUI
                        )
                        .accessibilityIdentifier(
                            "preparedOutputStayAction"
                        )
                    } else {
                        Button("Close".localizedUI) {
                            requestExportDismissal()
                        }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("officeExportDoneAction")
                        .disabled(model.isProcessing(recordID))
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                focusedDeliveryAction
            }
        }
    }

    private var exportPresentations: some View {
        AnyView(exportNavigation)
        .sheet(
            isPresented: $isSharing,
            onDismiss: cleanupTemporaryExports
        ) {
            ShareSheet(
                items: shareItems,
                removesTemporaryItemsOnCompletion: !preservesSharedTemporaryResult
            )
        }
        .sheet(isPresented: Binding(
            get: { filesExportURL != nil },
            set: { if !$0 { filesExportURL = nil } }
        ), onDismiss: cleanupTemporaryExports) {
            if let filesExportURL {
                FileExportPicker(url: filesExportURL, onCompletion: {
                    self.filesExportURL = nil
                }, onExported: { _ in
                    model[noticeFor: paperPathSceneID] = "PDF saved to Files".localizedUI
                })
                .ignoresSafeArea()
            }
        }
        .sheet(item: $officePreviewFile, onDismiss: cleanupOfficePreview) { file in
            OfficeOutputPreview(file: file)
        }
        .sheet(item: $inspectedOfficeReceipt) { receipt in
            OfficeEvidenceInspectorView(
                receipt: receipt,
                currentRevisionID: model.record(id: recordID)?
                    .contentRevisionID
            )
        }
        .fullScreenCover(
            isPresented: $isPreparingPrint,
            onDismiss: completePreparedOutputTransition
        ) {
            PrintPreparationSheet(recordID: recordID) { route in
                pendingPreparedRoute = route.bindingExpectedRevision(
                    model.record(id: route.recordID)?
                        .contentRevisionID
                )
                isPreparingPrint = false
            }
        }
        .fullScreenCover(
            isPresented: $isPreparingBooklet,
            onDismiss: completePreparedOutputTransition
        ) {
            BookletPreparationSheet(recordID: recordID) { route in
                pendingPreparedRoute = route.bindingExpectedRevision(
                    model.record(id: route.recordID)?
                        .contentRevisionID
                )
                isPreparingBooklet = false
            }
        }
        .confirmationDialog(
            "Discard unsaved Office output?".localizedUI,
            isPresented: $isConfirmingTemporaryResultDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard and close".localizedUI, role: .destructive) {
                cleanupTemporaryOfficeResult()
                dismiss()
            }
            Button("Keep working".localizedUI, role: .cancel) {}
        } message: {
            Text("Not saved to History. Source PDF unchanged.".localizedUI)
        }
    }

    var body: some View {
        AnyView(exportPresentations)
        .task(id: activeFocus) {
            if !didResolveInitialOfficeReceipt,
               let id = initialOfficeReceiptID,
               let receipt = model.record(id: recordID)?.officeReceipts.first(where: { $0.id == id }) {
                didResolveInitialOfficeReceipt = true
                officeReceipt = receipt
                selectedOfficeFormat = receipt.format
                didChooseOfficeFormat = true
            }
            guard activeFocus == .safeShare else { return }
            startPreflightIfNeeded()
        }
        .onChange(of: currentContentRevisionID) { oldValue, newValue in
            guard oldValue != newValue else { return }
            officePreviewPage = 0
            deliveryPreviewPage = 0
            showsDeliveryPagePicker = false
            usesOfficePageRange = false
            officeFirstPage = 1
            officeLastPage = 1
            officePreviewFile = nil
            inspectedOfficeReceipt = nil
            if temporaryOfficeResultURL != nil {
                officeResultNotice = "The source PDF changed. This output belongs to the earlier revision."
            }
            guard activeFocus == .safeShare else { return }
            invalidatePreflight()
            guard newValue != nil,
                  model.record(id: recordID)?
                    .hasCurrentDeliveryReceipt != true
            else { return }
            startPreflightIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            officePreviewFile = nil
            inspectedOfficeReceipt = nil
            cancelPreparedOutputTransition()
            if preflightTask != nil {
                stopPreflight(showNotice: false)
            }
            stopPreflightReviewHandoff(showNotice: false)
            if isSharing || filesExportURL != nil {
                filesExportURL = nil
                isSharing = false
                cleanupTemporaryExports()
            }
            if exportTask != nil {
                stopExportPreparation(invalidateResult: true)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            officePreviewFile = nil
            inspectedOfficeReceipt = nil
            cancelPreparedOutputTransition()
            if preflightTask != nil {
                stopPreflight(showNotice: false)
            }
            stopPreflightReviewHandoff(showNotice: false)
            if isSharing || filesExportURL != nil {
                filesExportURL = nil
                isSharing = false
                cleanupTemporaryExports()
            }
            if exportTask != nil {
                stopExportPreparation(invalidateResult: true)
            }
        }
        .onDisappear {
            cancelPreparedOutputTransition()
            cancelPreflightTask()
            stopPreflightReviewHandoff(showNotice: false)
            officeGovernanceTask?.cancel()
            officeGovernanceTask = nil
            if !isSharing, filesExportURL == nil, officePreviewFile == nil, inspectedOfficeReceipt == nil {
                stopExportPreparation(invalidateResult: true)
                cleanupTemporaryExports()
                cleanupTemporaryOfficeResult()
            }
        }
        .sensoryFeedback(.selection, trigger: officeRouteFeedback)
        .sensoryFeedback(.success, trigger: officeReceiptFeedback)
        .sensoryFeedback(.error, trigger: officeFailureFeedback)
        .sensoryFeedback(.selection, trigger: officePinFeedback)
        .sensoryFeedback(
            .success,
            trigger: preflightSuccessFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: preflightErrorFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: preflightReviewErrorFeedback
        )
        .sensoryFeedback(
            .selection,
            trigger: focusTransitionFeedback
        )
        .sensoryFeedback(
            .selection,
            trigger: selectedExportCatalogMode.rawValue
        )
        .sensoryFeedback(
            .success,
            trigger: preparedOutputTransitionFeedback
        )
        .accessibilityAction(.escape) {
            if exportTask != nil {
                stopExportPreparation()
            } else if preflightReviewTask != nil {
                stopPreflightReviewHandoff()
            } else if isPreparedOutputTransitionActive {
                cancelPreparedOutputTransition(showsNotice: true)
            } else if canReturnToExportCatalog {
                returnToExportCatalog()
            } else {
                requestExportDismissal()
            }
        }
        .interactiveDismissDisabled(
            exportTask != nil
                || preflightReviewTask != nil
                || isPreparedOutputTransitionActive
                || temporaryOfficeResultURL != nil
        )
        .modifier(OfficeExportPresentationSizing())
    }

    private var isOfficeWorkspace: Bool {
        activeFocus == .text || (activeFocus == nil && exportCatalogMode == .office)
    }

    private var usesWideDeliveryLayout: Bool {
        activeFocus == .safeShare && hasWideExportViewport
            && !dynamicTypeSize.ppPrefersExpandedLayout
    }

    private var exportWorkspace: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                if isOfficeWorkspace, hasWideExportViewport,
                   !dynamicTypeSize.isAccessibilitySize,
                   let record = model.record(id: recordID) {
                    officeSourcePreview(record)
                        .frame(width: 280)
                        .padding(PPSpacing.large)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(PPColor.surfaceMuted.opacity(0.4))
                } else if usesWideDeliveryLayout,
                          let record = model.record(id: recordID) {
                    ScrollView {
                        deliveryDocumentHeader(record, expanded: true)
                            .padding(PPSpacing.large)
                    }
                    .frame(width: 320)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(PPColor.documentStage)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: PPSpacing.regular) {
                        exportHeaderContent
                        safeShareContent
                        pdfExportContent
                        officeExportContent
                        imageExportContent
                        exportProgressContent
                    }
                    .frame(maxWidth: 760)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .id(activeFocus)
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                let isWide = width >= 860
                if hasWideExportViewport != isWide {
                    hasWideExportViewport = isWide
                }
            }
        }
    }

    @ViewBuilder
    private var exportHeaderContent: some View {
        if let record = model.record(id: recordID) {
            if isOfficeWorkspace {
                if officeReceipt == nil {
                    HStack(spacing: PPSpacing.medium) {
                    Image(systemName: "doc.text")
                        .font(.title2)
                        .foregroundStyle(PPColor.cyan)
                    VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                        Text(record.displayName)
                            .font(.headline)
                            .foregroundStyle(PPColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(record.subtitle)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PPColor.textSecondary)
                    }
                }
                }
            } else if activeFocus == .safeShare {
                if !usesWideDeliveryLayout {
                    deliveryDocumentHeader(record)
                }
            } else {
                exportContextHeader(record)
            }
        }

        if activeFocus == nil {
            Button {
                preparePDFShare(recordID: recordID, label: "PDF", toFiles: true)
            } label: {
                Label("Save PDF to Files".localizedUI, systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(exportTask != nil || model.isProcessing(recordID))
            .accessibilityIdentifier("exportSavePDFToFiles")
            Button {
                preparePDFShare(recordID: recordID, label: "PDF")
            } label: {
                Label("Share PDF".localizedUI, systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.accent))
            .disabled(exportTask != nil || model.isProcessing(recordID))
            .accessibilityIdentifier("exportSharePDF")
            exportCatalogPicker
        }
    }

    @ViewBuilder
    private var safeShareContent: some View {
        if let record = model.record(id: recordID),
           record.hasCurrentDeliveryReceipt,
           activeFocus != .safeShare {
            verifiedShareButton(record)
        }

        if activeFocus == .safeShare,
           model.record(id: recordID)?
            .hasCurrentDeliveryReceipt != true {
            OperationBoundaryNotice(
                title: "Export uses image-based pages",
                detail: "Checks every page and fingerprints the file. Not a legal certification.",
                identifier: "safeShareOutputBoundary",
                symbol: "checkmark.seal.fill",
                tint: PPColor.mint
            )
            preflightPanel
            if currentPreflight?.status == .blocked
                || preflightError != nil {
                recoveryActions
            }
        }
    }

    @ViewBuilder
    private var focusedDeliveryAction: some View {
        if let route = transitioningPreparedRoute ?? pendingPreparedRoute {
            preparedOutputHandoffBar(route)
        } else if isOfficeWorkspace, let record = model.record(id: recordID) {
            officeActionFooter(record)
        } else if activeFocus == .safeShare,
           let record = model.record(id: recordID) {
            let hasReceipt = record.hasCurrentDeliveryReceipt
            Button {
                if hasReceipt {
                    preparePDFShare(
                        recordID: record.id,
                        label: "verified PDF"
                    )
                } else {
                    startSafeShareCreation()
                }
            } label: {
                Label(
                    (hasReceipt
                        ? "Share Verified PDF"
                        : safeShareCreationTitle).localizedUI,
                    systemImage: hasReceipt
                        ? "square.and.arrow.up"
                        : safeShareCreationSymbol
                )
                .frame(maxWidth: .infinity)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(
                model.isProcessing(recordID)
                    || exportTask != nil
                    || preflightReviewTask != nil
                    || (
                        !hasReceipt
                            && (
                                currentPreflight == nil
                                    || currentPreflight?.status
                                        == .blocked
                            )
                    )
            )
            .frame(maxWidth: 760)
            .padding(PPSpacing.regular)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
            .accessibilityHint(
                hasReceipt
                    ? "Shares this checked export"
                    : safeShareCreationHint.localizedUI
            )
            .accessibilityIdentifier(
                hasReceipt
                    ? "shareVerifiedPDF"
                    : "safeShareButton"
            )
        }
    }

    private func preparedOutputHandoffBar(
        _ route: DocumentRoute
    ) -> some View {
        let displayTitle =
            model.record(id: route.recordID)?.displayName
                ?? "Exported PDF".localizedUI
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.medium) {
                preparedOutputHandoffIdentity(displayTitle)
                Spacer(minLength: PPSpacing.small)
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                preparedOutputStayButton
            }

            VStack(alignment: .leading, spacing: PPSpacing.small) {
                HStack(spacing: PPSpacing.small) {
                    preparedOutputHandoffIdentity(displayTitle)
                    Spacer(minLength: PPSpacing.small)
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                preparedOutputStayButton
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(
            AppLocalization.format(
                "Opening export %@",
                displayTitle
            )
        )
        .accessibilityIdentifier("preparedOutputHandoff")
    }

    private func preparedOutputHandoffIdentity(
        _ displayTitle: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Opening export".localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(verbatim: displayTitle)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout ? 3 : 1
                    )
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(PPColor.mint)
                .symbolEffect(
                    .bounce,
                    value: reduceMotion
                        ? 0
                        : preparedOutputTransitionFeedback
                )
        }
    }

    private var preparedOutputStayButton: some View {
        Button {
            cancelPreparedOutputTransition(showsNotice: true)
        } label: {
            Label("Stay here", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PPColor.textSecondary)
        .accessibilityLabel("Stay on this output sheet".localizedUI)
        .accessibilityHint(
            "Keeps the export in export history and stops automatic opening."
                .localizedUI
        )
        .help("Stay here".localizedUI)
        .accessibilityIdentifier("preparedOutputStayInline")
    }

    @ViewBuilder
    private var pdfExportContent: some View {
        if activeFocus == nil,
           exportCatalogMode == .pdf {
            DisclosureGroup(
                "More PDF options".localizedUI,
                isExpanded: $showsAdvancedPDFOptions
            ) {
                safeShareButton

                exportButton(
                    "Export Flattened PDF",
                    detail: "Image-based: removes search, links, forms, and editable layers",
                    symbol: "square.stack.3d.down.right",
                    identifier: "flattenedOutputOption"
                ) {
                    guard let sourceContentRevisionID =
                            currentContentRevisionID
                    else { return }
                    let existingDocumentIDs = Set(
                        model.documents.map(\.id)
                    )
                    let generation = beginExport(
                        label: "flattened copy"
                    )
                    exportTask = Task { @MainActor in
                        defer {
                            finishExport(generation)
                        }
                        let created = await model
                            .createFlattenedCopy(
                                recordID: recordID,
                                expectedContentRevisionID:
                                    sourceContentRevisionID,
                                forExport: true
                            )
                        guard exportGeneration == generation else {
                            return
                        }
                        let committed = created
                            ?? model.documents.first {
                                !existingDocumentIDs.contains($0.id)
                                    && $0.sourceDocumentID == recordID
                                    && $0.deliveryReceipt?.operation
                                        == .flattened
                            }
                        if exportStopRequested || Task.isCancelled {
                            model[noticeFor: paperPathSceneID] = (
                                committed == nil
                                    ? "Flattened copy creation stopped"
                                    : "Flattened copy finished before stopping · copy kept in Library"
                            ).localizedUI
                            return
                        }
                        guard exportIsCurrent(generation),
                              let created
                        else { return }
                        onCreated(
                            DocumentRoute(
                                recordID: created.id
                            )
                        )
                    }
                }

                exportButton(
                    "Print-Ready PDF",
                    symbol: "printer.fill",
                    badge: "PDF"
                ) {
                    isPreparingPrint = true
                }

                exportButton(
                    "Booklet PDF",
                    symbol: "book.pages.fill",
                    badge: "2-UP"
                ) {
                    isPreparingBooklet = true
                }
            }
            .tint(PPColor.accent)
            .padding(.vertical, PPSpacing.small)
        }
    }

    @ViewBuilder
    private var officeExportContent: some View {
        if activeFocus == .text
            || (
                activeFocus == nil
                    && exportCatalogMode == .office
            ) {
            AnyView(officeFormatContent)
            if officeReceipt == nil {
                portableTextFormatContent
            }
        }
    }

    @ViewBuilder
    private var officeFormatContent: some View {
        if officeReceipt == nil, let officeResultNotice {
            Label(officeResultNotice.localizedUI, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let officeFailure,
           let record = model.record(id: recordID) {
            officeExportFailurePanel(
                officeFailure,
                record: record
            )
        }
        if let officeReceipt,
           let record = model.record(id: recordID) {
            officeResultSummary(officeReceipt, record: record)
        }
        if let record = model.record(id: recordID) {
            let portfolio = PDFOfficeExportPortfolio(
                profile: record.profile
            )
            if let batchRun = model.officeBatchRun(
                for: recordID
            ) {
                AnyView(officeBatchRunPanel(
                    batchRun,
                    record: record
                ))
            }
            if officeReceipt == nil {
                officeGuidedChoice(
                    record,
                    portfolio: portfolio
                )
            }
            if showsOfficeEvidence, officeReceipt == nil {
                AnyView(VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    OfficeClockContinuitySection()
                    officeReadinessStrip(
                        record,
                        portfolio: portfolio
                    )
                    officeDecisionStrip(portfolio)
                    officePreflightStrip(portfolio)
                    officeBudgetStrip(
                        portfolio.visualBudgetPlan
                    )
                })
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                )
            }
            officeRecentResults(record)
        } else {
            ForEach(officeFormats) { format in
                officeFormatButton(
                    format,
                    plan: nil,
                    sourcePageCount: 0,
                    isRecommended: false
                )
            }
        }
    }

    @ViewBuilder
    private var portableTextFormatContent: some View {
        Button {
            withAnimation(
                reduceMotion
                    ? nil
                    : .snappy(duration: 0.2)
            ) {
                showsPortableTextFormats.toggle()
            }
        } label: {
            HStack {
                Label(
                    (showsPortableTextFormats
                        ? "Hide text-only formats"
                        : "Text formats").localizedUI,
                    systemImage: "text.alignleft"
                )
                Spacer()
                Image(
                    systemName:
                        showsPortableTextFormats
                            ? "chevron.up"
                            : "chevron.down"
                )
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.textSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showsPortableTextFormats {
            outputSection(
                title: "TEXT-ONLY FORMATS",
                detail:
                    "Maximum compatibility without page layout",
                symbol: "text.alignleft",
                tint: PPColor.rose
            ) {
                ForEach(portableTextFormats) { format in
                    exportButton(
                        format.title,
                        detail: format.detail,
                        symbol: format.symbol,
                        badge:
                            format.fileExtension
                                .uppercased()
                    ) {
                        startTextExport(format)
                    }
                }
            }
            .transition(
                .move(edge: .top)
                    .combined(with: .opacity)
            )
        }
    }

    @ViewBuilder
    private var imageExportContent: some View {
        if activeFocus == .images
            || (
                activeFocus == nil
                    && exportCatalogMode == .images
            ) {
            outputSection(
                title: "PAGE IMAGES",
                symbol: "photo.on.rectangle.angled",
                tint: PPColor.amber
            ) {
                ForEach(
                    PDFPageImageExportPreset.allCases
                ) { preset in
                    exportButton(
                        preset.title,
                        symbol: preset.symbol,
                        badge: pageImageBadge(preset),
                        identifier:
                            "exportPageImages-\(preset.rawValue)"
                    ) {
                        let generation = beginExport(
                            label: preset.title.lowercased()
                        )
                        exportTask = Task { @MainActor in
                            defer {
                                finishExport(generation)
                            }
                            let urls = await model
                                .makePageImageExports(
                                    recordID: recordID,
                                    preset: preset
                                )
                            guard !urls.isEmpty else {
                                return
                            }
                            guard exportIsCurrent(
                                generation
                            ) else {
                                await model
                                    .discardTemporaryExportCopies(
                                        at: urls
                                    )
                                return
                            }
                            share(
                                urls,
                                temporaryURLs: urls
                            )
                        }
                    }
                }
            }

            outputSection(
                title: "EMBEDDED ASSETS",
                symbol: "photo.stack",
                tint: PPColor.mint
            ) {
                exportButton(
                    "Embedded Images",
                    symbol: "photo.stack",
                    badge: "ASSETS"
                ) {
                    let generation = beginExport(
                        label: "embedded images"
                    )
                    exportTask = Task { @MainActor in
                        defer {
                            finishExport(generation)
                        }
                        let urls = await model
                            .makeEmbeddedImageExports(
                                recordID: recordID
                            )
                        guard !urls.isEmpty else {
                            return
                        }
                        guard exportIsCurrent(
                            generation
                        ) else {
                            await model
                                .discardTemporaryExportCopies(
                                    at: urls
                                )
                            return
                        }
                        share(
                            urls,
                            temporaryURLs: urls
                        )
                    }
                }
                .accessibilityIdentifier(
                    "exportEmbeddedImages"
                )
            }
        }
    }

    @ViewBuilder
    private var exportProgressContent: some View {
        if let exportLabel, !isOfficeWorkspace {
            if let officeShareProgress {
                LocalOperationProgressView(
                    progress: officeShareProgress
                )
            } else if model.officeBatchRun(
                for: recordID
            ) != nil {
                EmptyView()
            } else if let pdfShareProgress {
                LocalOperationProgressView(
                    progress: pdfShareProgress
                )
            } else if let activeOfficeFormat,
                      let record = model.record(id: recordID) {
                officeExportProgressPanel(
                    exportLabel,
                    format: activeOfficeFormat,
                    record: record
                )
            } else if let progress = model.progress(for: recordID) {
                LocalOperationProgressView(progress: progress)
            } else {
                HStack(spacing: PPSpacing.medium) {
                    ProgressView()
                    Text(
                        AppLocalization.format(
                            "Preparing %@ on device",
                            exportLabel.localizedUI
                        )
                    )
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var navigationTitle: String {
        if isOfficeWorkspace { return "Convert PDF" }
        switch activeFocus {
        case .safeShare: return "Finish & Share"
        case .text: return "Convert PDF"
        case .images: return "Save as Images"
        case nil: return "Create & Share"
        }
    }

    private var canReturnToExportCatalog: Bool {
        initialFocus == nil
            && activeFocus != nil
            && !isPreparedOutputTransitionActive
            && temporaryOfficeResultURL == nil
    }

    private var isPreparedOutputTransitionActive: Bool {
        pendingPreparedRoute != nil
            || transitioningPreparedRoute != nil
            || preparedOutputTransitionTask != nil
    }

    private func enterSafeShareFlow() {
        guard activeFocus != .safeShare,
              exportTask == nil,
              preflightReviewTask == nil,
              model.record(id: recordID) != nil
        else { return }
        focusTransitionFeedback &+= 1
        withAnimation(
            reduceMotion ? nil : .snappy(duration: 0.22)
        ) {
            activeFocus = .safeShare
        }
    }

    private func returnToExportCatalog() {
        guard canReturnToExportCatalog,
              exportTask == nil,
              preflightReviewTask == nil,
              !isPreparedOutputTransitionActive,
              temporaryOfficeResultURL == nil
        else { return }
        invalidatePreflight()
        focusTransitionFeedback &+= 1
        withAnimation(
            reduceMotion ? nil : .snappy(duration: 0.22)
        ) {
            activeFocus = nil
        }
    }

    private var officeFormats: [PDFTextExportFormat] {
        [.wordDocument, .excelWorkbook, .powerPointPresentation]
    }

    private func officeSourcePreview(_ record: DocumentRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPSpacing.large) {
                Text("Source PDF".localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                if !hideLibraryPreviews, !record.profile.isLocked,
                   let url = model.url(for: recordID) {
                    PDFPageThumbnailView(
                        url: url,
                        pageIndex: min(officePreviewPage, max(0, record.profile.pageCount - 1)),
                        refreshToken: model.refreshToken(for: recordID),
                        width: 224
                    )
                    .frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                } else {
                    Image(systemName: record.profile.isLocked ? "lock.doc" : "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(PPColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 280)
                }
                HStack {
                    DeskIconButton(title: "Previous page", symbol: "chevron.left") {
                        officePreviewPage = max(0, officePreviewPage - 1)
                    }
                    .disabled(officePreviewPage == 0 || record.profile.isLocked)
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                    Text(AppLocalization.format(
                        "Page %lld of %lld", officePreviewPage + 1, max(1, record.profile.pageCount)
                    ))
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity)
                    DeskIconButton(title: "Next page", symbol: "chevron.right") {
                        officePreviewPage = min(record.profile.pageCount - 1, officePreviewPage + 1)
                    }
                    .disabled(officePreviewPage >= record.profile.pageCount - 1 || record.profile.isLocked)
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                }
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("The source file remains unchanged.".localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("officeSourcePreview")
    }

    private func officeFormatSelection(
        _ plan: PDFOfficeExportFormatPlan, recommended: Bool
    ) -> some View {
        let selected = selectedOfficeFormat == plan.format
        return Button {
            if selectedOfficeFormat != plan.format {
                officeReceipt = nil
                officeResultNotice = nil
            }
            selectedOfficeFormat = plan.format
            didChooseOfficeFormat = true
            officeFailure = nil
            officeRouteFeedback += 1
        } label: {
            HStack(alignment: .center, spacing: PPSpacing.medium) {
                Image(systemName: plan.format.symbol)
                    .font(.title3)
                    .foregroundStyle(officeReadinessColor(plan.readiness))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                    Text(plan.format.title.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    Text(officePurposeLine(plan.format).localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if recommended {
                        Text("Recommended".localizedUI)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PPColor.mint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? PPColor.accent : PPColor.textSecondary)
            }
            .padding(PPSpacing.medium)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(selected ? PPColor.accent.opacity(0.07) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(exportTask != nil || temporaryOfficeResultURL != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plan.format.title.localizedUI)
        .accessibilityHint(officePurposeLine(plan.format).localizedUI)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("officeFormat-\(plan.format.rawValue)")
    }

    private func officeActionFooter(_ record: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            if exportTask != nil {
                HStack(spacing: PPSpacing.medium) {
                    if let progress = officeShareProgress ?? model.progress(for: recordID) {
                        LocalOperationProgressView(progress: progress)
                    } else {
                        ProgressView()
                        Text((exportLabel ?? "Preparing output").localizedUI)
                            .font(.subheadline)
                    }
                    Spacer(minLength: 0)
                    DeskIconButton(title: "Stop", symbol: "stop.fill", tint: PPColor.amber) {
                        stopExportPreparation()
                    }
                    .disabled(exportStopRequested)
                }
            } else if let receipt = officeReceipt,
                      receipt.format == selectedOfficeFormat {
                officeResultActions(receipt, record: record)
            } else {
                Button {
                    startTextExport(selectedOfficeFormat)
                } label: {
                    Label(
                        AppLocalization.format("Convert to %@", selectedOfficeFormat.title.localizedUI),
                        systemImage: "arrow.right.doc.on.clipboard"
                    )
                    .foregroundStyle(PPColor.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    record.profile.isLocked || model.isProcessing(recordID)
                        || temporaryOfficeResultURL != nil
                        || officePageRangeError(record, format: selectedOfficeFormat) != nil
                )
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("officeConvertAction")
            }
        }
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(PPColor.border).frame(height: 0.5)
        }
    }

    private func officeResultSummary(
        _ receipt: PDFOfficeExportReceipt, record: DocumentRecord
    ) -> some View {
        let availability = receipt.artifactAvailability(for: record.contentRevisionID)
        let resultTitle = temporaryOfficeResultURL != nil ? "Output not saved"
            : availability != .reusable ? availability.title
            : receipt.batchID != nil ? "Office part saved"
            : "Output saved locally"
        return VStack(alignment: .leading, spacing: PPSpacing.medium) {
            Label(
                resultTitle.localizedUI,
                systemImage: temporaryOfficeResultURL == nil ? "internaldrive" : "exclamationmark.circle"
            )
            .font(PPType.metadata)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .foregroundStyle(temporaryOfficeResultURL == nil ? PPColor.textSecondary : PPColor.amber)
            Text(receipt.fileName)
                .font(PPType.section)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("\(receipt.format.fileExtension.uppercased())  ·  \(receipt.formattedSize)")
                .font(PPType.measure)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(PPColor.textSecondary)
            if let sourcePages = receipt.sourcePageSummary {
                Label(sourcePages, systemImage: "doc.on.doc")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
            }
            if temporaryOfficeResultURL == nil, availability == .reusable {
                OfficeInlineOutputPreview(
                    recordID: recordID, revisionID: record.contentRevisionID, receipt: receipt
                ) {
                    shareRetainedOfficeExport(receipt, previewing: true)
                }
                .id(receipt.id)
            }
            if !receipt.contentNotices.isEmpty {
                Text("Review converted content".localizedUI)
                    .font(PPType.section)
                    .accessibilityAddTraits(.isHeader)
                OfficeContentNoticesView(receipt: receipt, compact: true)
            }
            if let officeResultNotice {
                Text(officeResultNotice.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if availability != .reusable {
                Label(
                    (availability == .reusable && !receipt.contentNotices.isEmpty
                        ? "Output saved locally" : availability.title).localizedUI,
                    systemImage: availability == .reusable && !receipt.contentNotices.isEmpty
                        ? "internaldrive" : availability.symbol
                )
                    .font(.caption)
                    .foregroundStyle(availability == .reusable ? PPColor.textSecondary : PPColor.amber)
            }
            Button {
                inspectedOfficeReceipt = receipt
            } label: {
                Label("View conversion checks", systemImage: "checklist.checked")
                    .font(.caption)
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("officeConversionChecks")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PPSpacing.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("officeConversionResult")
    }

    private func officeResultActions(
        _ receipt: PDFOfficeExportReceipt, record: DocumentRecord
    ) -> some View {
        let reusable = receipt.artifactAvailability(for: record.contentRevisionID) == .reusable
        let layout = dynamicTypeSize.ppPrefersExpandedLayout && temporaryOfficeResultURL != nil
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PPSpacing.small))
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))
        return layout {
            if temporaryOfficeResultURL != nil {
                Button {
                    retryRetainingOfficeResult()
                } label: {
                    Label("Retry saving output", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }
                .disabled(receipt.sourceRevisionID != record.contentRevisionID)
                Button {
                    if let url = temporaryOfficeResultURL {
                        share([url], preservesTemporaryResult: true)
                    }
                } label: {
                    Label("Share output", systemImage: "square.and.arrow.up")
                        .frame(minHeight: 44)
                }
            } else {
                DeskIconButton(title: "Preview output", symbol: "doc.text.magnifyingglass") {
                    shareRetainedOfficeExport(receipt, previewing: true)
                }
                .disabled(!reusable)
                Button {
                    shareRetainedOfficeExport(receipt)
                } label: {
                    Label("Share output", systemImage: "square.and.arrow.up")
                        .foregroundStyle(PPColor.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!reusable)
                DeskIconButton(title: "Convert again", symbol: "arrow.clockwise", tint: PPColor.textSecondary) {
                    officeReceipt = nil
                    officeResultNotice = nil
                }
            }
        }
        .disabled(model.isProcessing(recordID) || officeGovernanceTask != nil)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("officeResultActions")
    }

    private func officeRecentResults(_ record: DocumentRecord) -> some View {
        let history = record.officeReceipts.filter { $0.id != officeReceipt?.id }
        let query = officeHistoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let receipts = history.filter {
            (officeHistoryFormat == nil || $0.format == officeHistoryFormat)
                && (!officeHistoryCurrentOnly || $0.sourceRevisionID == record.contentRevisionID)
                && (query.isEmpty || $0.fileName.localizedStandardContains(query)
                    || $0.sourcePageSummary?.localizedStandardContains(query) == true)
        }.sorted { $0.exportedAt > $1.exportedAt }
        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            if !history.isEmpty {
                HStack {
                    Text("Recent Office outputs".localizedUI)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if history.count > 3 {
                        Button {
                            showsOfficeHistory.toggle()
                        } label: {
                            Image(systemName: showsOfficeHistory ? "chevron.up" : "chevron.down")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel((showsOfficeHistory ? "Show less" : "Show all").localizedUI)
                    }
                }
                if showsOfficeHistory || history.count > 3 {
                    HStack(spacing: PPSpacing.small) {
                        TextField("Search outputs".localizedUI, text: $officeHistoryQuery)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Menu {
                            Picker("Format".localizedUI, selection: $officeHistoryFormat) {
                                Text("All formats".localizedUI).tag(Optional<PDFTextExportFormat>.none)
                                ForEach(officeFormats) { format in
                                    Text(format.title.localizedUI).tag(Optional(format))
                                }
                            }
                            Toggle("Current revision only".localizedUI, isOn: $officeHistoryCurrentOnly)
                            if officeHistoryFormat != nil || officeHistoryCurrentOnly || !query.isEmpty {
                                Button("Clear filters".localizedUI) {
                                    officeHistoryFormat = nil
                                    officeHistoryCurrentOnly = false
                                    officeHistoryQuery = ""
                                }
                            }
                        } label: {
                            Image(systemName: officeHistoryFormat != nil || officeHistoryCurrentOnly
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Filter outputs".localizedUI)
                        .help("Filter outputs".localizedUI)
                    }
                    .onChange(of: officeHistoryQuery) { _, value in
                        if value.count > 256 { officeHistoryQuery = String(value.prefix(256)) }
                    }
                }
                if receipts.isEmpty {
                    Label("No matching outputs".localizedUI, systemImage: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textSecondary)
                        .frame(minHeight: 44)
                }
                ForEach(Array(receipts.prefix(showsOfficeHistory ? receipts.count : 3))) { receipt in
                    HStack(spacing: PPSpacing.small) {
                        Button {
                            officeReceipt = receipt
                            selectedOfficeFormat = receipt.format
                            didChooseOfficeFormat = true
                            officeFailure = nil
                            officeResultNotice = nil
                            if receipt.sourceRevisionID == record.contentRevisionID,
                               let first = receipt.sourcePageStartIndex,
                               let last = receipt.sourcePageEndIndex,
                               first >= 0, last >= first, last < record.profile.pageCount {
                                usesOfficePageRange = true
                                officeFirstPage = first + 1
                                officeLastPage = last + 1
                            } else {
                                usesOfficePageRange = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                                Text(receipt.fileName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(PPColor.textPrimary)
                                    .lineLimit(2)
                                Text(receipt.artifactAvailability(for: record.contentRevisionID).title.localizedUI)
                                    .font(.caption)
                                    .foregroundStyle(PPColor.textSecondary)
                                if !receipt.contentNotices.isEmpty {
                                    Label("Review converted content".localizedUI, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(PPColor.amber)
                                }
                                Text("\(receipt.format.fileExtension.uppercased()) · \(receipt.formattedSize) · \(receipt.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(PPColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let sourcePages = receipt.sourcePageSummary {
                                    Text(sourcePages)
                                        .font(.caption2)
                                        .foregroundStyle(PPColor.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        officeReceiptMenu(receipt, availability: receipt.artifactAvailability(for: record.contentRevisionID))
                    }
                }
            }
        }
        .disabled(exportTask != nil || temporaryOfficeResultURL != nil)
    }

    private func requestExportDismissal() {
        if temporaryOfficeResultURL != nil {
            isConfirmingTemporaryResultDiscard = true
        } else {
            dismiss()
        }
    }

    private func cleanupTemporaryOfficeResult() {
        guard let url = temporaryOfficeResultURL else { return }
        temporaryOfficeResultURL = nil
        Task { await model.discardTemporaryExportCopies(at: [url]) }
    }

    private func cleanupOfficePreview() {
        guard let url = officePreviewCopyURL else { return }
        officePreviewCopyURL = nil
        Task { await model.discardTemporaryExportCopies(at: [url]) }
    }

    private func retryRetainingOfficeResult() {
        guard let receipt = officeReceipt, let url = temporaryOfficeResultURL,
              let revision = receipt.sourceRevisionID,
              exportTask == nil, !model.isProcessing(recordID)
        else { return }
        let generation = beginExport(label: "Saving Office output")
        exportTask = Task { @MainActor in
            defer { finishExport(generation) }
            let retained = await model.retainOfficeExport(
                recordID: recordID, receipt: receipt, sourceURL: url,
                expectedContentRevisionID: revision
            )
            if let retained {
                if temporaryOfficeResultURL == url {
                    temporaryOfficeResultURL = nil
                }
                if exportGeneration == generation, scenePhase == .active {
                    officeReceipt = retained.receipt
                    officeResultNotice = exportIsCurrent(generation)
                        ? nil : "A completed output was kept in local history."
                }
            } else if exportIsCurrent(generation) {
                officeResultNotice = "Output still available. Free space, retry, or share before closing."
            }
        }
    }

    private var portableTextFormats: [PDFTextExportFormat] {
        [.richText, .markdown, .plainText]
    }

    private var exportCatalogMode: ExportCatalogMode {
        selectedExportCatalogMode
    }

    private var exportCatalogPicker: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "CHOOSE A FORMAT",
                symbol: "dial.medium",
                tint: PPColor.rose
            )

            if dynamicTypeSize.ppPrefersExpandedLayout {
                LazyVGrid(
                    columns: [GridItem(.flexible())],
                    spacing: 0
                ) {
                    ForEach(ExportCatalogMode.allCases.filter { $0 != .recommended }) { mode in
                        exportCatalogButton(mode)
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        ForEach(ExportCatalogMode.allCases.filter { $0 != .recommended }) { mode in
                            exportCatalogButton(mode)
                        }
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ],
                        spacing: 0
                    ) {
                        ForEach(ExportCatalogMode.allCases.filter { $0 != .recommended }) { mode in
                            exportCatalogButton(mode)
                        }
                    }
                }
            }
        }
    }

    private func exportCatalogButton(
        _ mode: ExportCatalogMode
    ) -> some View {
        let selected = exportCatalogMode == mode
        let tint = exportCatalogTint(mode)
        return Button {
            withAnimation(
                reduceMotion ? nil : .snappy(duration: 0.2)
            ) {
                selectedExportCatalogMode = mode
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: exportCatalogSymbol(mode))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    if selected {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                    }
                }
                Text(mode.title.localizedUI)
                    .font(.caption.weight(.semibold))
                    .fontDesign(selected ? .serif : .default)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                    )
            }
            .foregroundStyle(selected ? tint : PPColor.textSecondary)
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 58)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(
                        selected
                            ? tint
                            : PPColor.border.opacity(0.55)
                    )
                    .frame(height: selected ? 2 : 0.6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(exportTask != nil || temporaryOfficeResultURL != nil)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityIdentifier(
            "exportCatalogMode-\(mode.rawValue)"
        )
    }

    private func exportCatalogSymbol(
        _ mode: ExportCatalogMode
    ) -> String {
        switch mode {
        case .recommended: return "target"
        case .pdf: return "doc.richtext"
        case .office: return "doc.badge.arrow.up"
        case .images: return "photo.stack"
        }
    }

    private func exportCatalogTint(
        _ mode: ExportCatalogMode
    ) -> Color {
        switch mode {
        case .recommended: return PPColor.mint
        case .pdf: return PPColor.accent
        case .office: return PPColor.cyan
        case .images: return PPColor.amber
        }
    }

    @ViewBuilder
    private func outputSection<Content: View>(
        title: String,
        detail: String? = nil,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: title,
                detail: detail,
                symbol: symbol,
                tint: tint
            )
            content()
        }
        .padding(.vertical, PPSpacing.xSmall)
        .accessibilityElement(children: .contain)
    }

    private func exportContextHeader(
        _ record: DocumentRecord
    ) -> some View {
        let title: String
        let symbol: String
        let tint: Color
        switch activeFocus {
        case .safeShare:
            title = "Prepare trusted delivery"
            symbol = "checkmark.shield"
            tint = PPColor.mint
        case .text:
            title = record.displayName
            symbol = "doc.badge.arrow.up"
            tint = PPColor.accent
        case .images:
            title = record.displayName
            symbol = "photo.stack"
            tint = PPColor.cyan
        case nil:
            title = record.displayName
            symbol = "square.and.arrow.up"
            tint = PPColor.accent
        }

        return WorkflowCommandHeader(
            title: title,
            symbol: symbol,
            tint: tint,
            metrics: [
                WorkflowMetric(
                    value: "\(record.profile.pageCount)",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value:
                        record.profile.formattedSize,
                    label: "Size",
                    symbol: "internaldrive",
                    tint: PPColor.cyan
                )
            ],
            showsOnDevice: activeFocus == .safeShare
        )
    }

    private func deliveryDocumentHeader(
        _ record: DocumentRecord, expanded: Bool = false
    ) -> some View {
        let layout = expanded || dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PPSpacing.regular))
            : AnyLayout(HStackLayout(alignment: .center, spacing: PPSpacing.regular))
        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            layout {
                if !dynamicTypeSize.isAccessibilitySize {
                    Button {
                        openDeliveryPreview(record)
                    } label: {
                        Group {
                            if !hideLibraryPreviews, !record.profile.isLocked,
                               let url = model.url(for: record.id) {
                                PDFPageThumbnailView(
                                    url: url, pageIndex: deliveryPreviewPage,
                                    refreshToken: model.refreshToken(for: record.id),
                                    width: expanded ? 240 : 104
                                )
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                            } else {
                                Image(systemName: record.profile.isLocked ? "lock.doc" : "eye.slash")
                                    .font(.title)
                                    .foregroundStyle(PPColor.textSecondary)
                                    .frame(width: expanded ? 240 : 104, height: expanded ? 307 : 133)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        hideLibraryPreviews || record.profile.isLocked
                            || exportTask != nil || preflightReviewTask != nil
                            || model.isProcessing(record.id)
                    )
                    .accessibilityLabel("Open page preview".localizedUI)
                    .accessibilityIdentifier("openDeliveryPagePreview")
                    .help("Open page preview".localizedUI)
                    .frame(maxWidth: expanded ? .infinity : nil)
                }
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    Text(record.displayName)
                        .font(.headline)
                        .foregroundStyle(PPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(record.subtitle.localizedUI)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                    Label(
                        (record.hasCurrentDeliveryReceipt ? "Verified copy" : "Document").localizedUI,
                        systemImage: record.hasCurrentDeliveryReceipt ? "checkmark.seal" : "doc.on.doc"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(record.hasCurrentDeliveryReceipt ? PPColor.mint : PPColor.textSecondary)
                    if dynamicTypeSize.isAccessibilitySize,
                       !hideLibraryPreviews, !record.profile.isLocked {
                        Button {
                            openDeliveryPreview(record)
                        } label: {
                            Label("Open page preview".localizedUI, systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.subheadline)
                                .frame(minHeight: 44)
                        }
                        .disabled(exportTask != nil || preflightReviewTask != nil || model.isProcessing(record.id))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(PPSpacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PPColor.documentStage)

            if !record.profile.isLocked, let url = model.url(for: record.id) {
                PDFPageFilmstrip(
                    url: url, pageCount: record.profile.pageCount,
                    refreshToken: model.refreshToken(for: record.id),
                    selectedPage: Binding(
                        get: { deliveryPreviewPage },
                        set: { page in
                            guard currentContentRevisionID == record.contentRevisionID else { return }
                            deliveryPreviewPage = page
                        }
                    ),
                    showsThumbnails: !hideLibraryPreviews && !dynamicTypeSize.isAccessibilitySize
                ) {
                    deliveryPageInput = String(deliveryPreviewPage + 1)
                    showsDeliveryPagePicker = true
                }
                .id(record.contentRevisionID)
                .disabled(exportTask != nil || preflightReviewTask != nil)
                .popover(isPresented: $showsDeliveryPagePicker) {
                    deliveryPagePicker(record)
                }
            }
        }
        .accessibilityIdentifier("deliveryDocumentPreview")
    }

    private func deliveryPagePicker(_ record: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            Text("Go to page".localizedUI).font(.headline)
            TextField("Page number".localizedUI, text: $deliveryPageInput)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .onSubmit { selectDeliveryPage(record) }
            Text(AppLocalization.format(
                "Page numbers must be between 1 and %lld.", record.profile.pageCount
            ))
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            Button {
                selectDeliveryPage(record)
            } label: {
                Label("Go".localizedUI, systemImage: "arrow.right")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(validDeliveryPage(record) == nil)
        }
        .padding(PPSpacing.regular)
        .frame(minWidth: 240, maxWidth: 340)
        .onChange(of: deliveryPageInput) { _, input in
            if input.count > 8 { deliveryPageInput = String(input.prefix(8)) }
        }
    }

    private func validDeliveryPage(_ record: DocumentRecord) -> Int? {
        guard currentContentRevisionID == record.contentRevisionID,
              let page = Int(deliveryPageInput.trimmingCharacters(in: .whitespaces)),
              (1...max(1, record.profile.pageCount)).contains(page)
        else { return nil }
        return page - 1
    }

    private func selectDeliveryPage(_ record: DocumentRecord) {
        guard let page = validDeliveryPage(record) else { return }
        deliveryPreviewPage = page
        showsDeliveryPagePicker = false
    }

    private func openDeliveryPreview(_ record: DocumentRecord) {
        guard currentContentRevisionID == record.contentRevisionID,
              !record.profile.isLocked, !hideLibraryPreviews,
              exportTask == nil, !model.isProcessing(record.id),
              (0..<record.profile.pageCount).contains(deliveryPreviewPage)
        else { return }
        openPreflightReview(PDFDeliveryPreflightItem(
            id: "document-preview",
            title: "Page preview",
            detail: "",
            status: .passed,
            reviewPageIndex: deliveryPreviewPage
        ))
    }

    private func verifiedShareButton(
        _ record: DocumentRecord
    ) -> some View {
        Button {
            preparePDFShare(
                recordID: record.id,
                label: "verified PDF"
            )
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share Verified PDF")
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(
                        record.deliveryReceipt?.shortFingerprint
                            ?? "Receipt available"
                    )
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(PPColor.textSecondary)
                }
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(PPColor.mint)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 52)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(PPColor.mint.opacity(0.76))
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(
            "Prepares this checked PDF for sharing"
        )
        .accessibilityIdentifier("shareVerifiedPDF")
    }

    private var safeShareButton: some View {
        Button {
            if activeFocus == .safeShare {
                startSafeShareCreation()
            } else {
                enterSafeShareFlow()
            }
        } label: {
            HStack(spacing: PPSpacing.regular) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(PPColor.surface)
                        .frame(width: 34, height: 44)
                        .rotationEffect(.degrees(-6))
                        .offset(x: -4)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(PPColor.elevated)
                        .frame(width: 34, height: 44)
                        .rotationEffect(.degrees(3))
                        .offset(x: 4)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.headline)
                        .foregroundStyle(PPColor.mint)
                        .offset(x: 10, y: 14)
                }
                .frame(width: 56, height: 54)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("Prepare Export")
                            .font(.headline)
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                        Text(verifiedAccessBadge.localizedUI)
                            .font(.caption2.smallCaps().weight(.bold))
                            .foregroundStyle(verifiedAccessTint)
                    }
                    Text(
                        "Prepares an image-based export and checks every page. The current document stays editable."
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
            }
            .padding(.horizontal, PPSpacing.small)
            .padding(.vertical, PPSpacing.small)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(PPColor.mint.opacity(0.76))
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(
            model.isProcessing(recordID)
                || exportTask != nil
                || (
                    activeFocus == .safeShare
                        && (
                            preflight == nil
                                || preflight?.status == .blocked
                        )
                )
        )
        .accessibilityHint(
            verifiedAccessHint.localizedUI
        )
        .accessibilityIdentifier("safeShareButton")
    }

    private var verifiedAccessBadge: String { "VERIFY" }

    private var verifiedAccessTint: Color { PPColor.mint }

    private var verifiedAccessHint: String {
        "Creates a separate image-based PDF and verifies the result"
    }

    private var safeShareCreationTitle: String {
        guard let preflight = currentPreflight else {
            if preflightPaused {
                return "Check Stopped"
            }
            if preflightError != nil {
                return "Check Failed"
            }
            return "Checking PDF"
        }
        switch preflight.status {
        case .ready:
            return "Prepare Export"
        case .review:
            return "Prepare Export"
        case .blocked:
            return "Resolve Before Creating"
        }
    }

    private var safeShareCreationSymbol: String {
        guard let preflight = currentPreflight else {
            if preflightPaused {
                return "pause.circle"
            }
            if preflightError != nil {
                return "exclamationmark.circle"
            }
            return "hourglass"
        }
        switch preflight.status {
        case .ready:
            return "checkmark.shield"
        case .review:
            return "exclamationmark.shield"
        case .blocked:
            return "xmark.shield"
        }
    }

    private var safeShareCreationHint: String {
        if preflightPaused {
            return "Retry the on-device check before creating a verified copy"
        }
        if preflightError != nil {
            return "Resolve the check error or retry before creating a verified copy"
        }
        if currentPreflight?.status == .review {
            return "Prepares an export and records remaining warnings"
        }
        if currentPreflight?.status == .blocked {
            return "Review the blocking item before creating an output"
        }
        return verifiedAccessHint
    }

    @ViewBuilder
    private var preflightPanel: some View {
        if let preflight = currentPreflight {
            VStack(alignment: .leading, spacing: PPSpacing.medium) {
                HStack(spacing: PPSpacing.medium) {
                    Image(systemName: preflight.status.symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(preflightColor(preflight.status))
                        .frame(width: 34, height: 34)
                        .background(
                            preflightColor(preflight.status).opacity(0.09),
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(preflight.status.title.localizedUI)
                            .font(.headline)
                            .foregroundStyle(PPColor.textPrimary)
                        Text(
                            "\(preflight.pageCount) pages · \(preflight.formattedSize)"
                        )
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textSecondary)
                    }

                    Spacer()

                }

                preflightSummary(preflight)

                if preflight.status == .ready, !usesWideDeliveryLayout {
                    preflightItemsList(preflight.items.filter { $0.status != .passed })
                    DisclosureGroup {
                        preflightItemsList(preflight.items.filter { $0.status == .passed })
                    } label: {
                        Label(
                            "Review checks",
                            systemImage: "checklist"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                    }
                } else {
                    preflightItemsList(preflight.items)
                }
            }
            .padding(.vertical, PPSpacing.small)
            .accessibilityIdentifier("deliveryPreflight")
        } else if let preflightError {
            Label(
                preflightError.localizedUI,
                systemImage: "xmark.octagon"
            )
                .font(.subheadline)
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("deliveryPreflightError")
        } else if preflightPaused {
            preflightStoppedPanel
        } else {
            preflightLoadingPanel
        }
    }

    private func preflightSummary(_ assessment: PDFDeliveryPreflightAssessment) -> some View {
        let statuses: [PDFDeliveryPreflightItemStatus] = [.passed, .willFix, .review, .blocked]
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PPSpacing.small))
            : AnyLayout(HStackLayout(alignment: .top, spacing: PPSpacing.medium))
        return layout {
            ForEach(statuses, id: \.rawValue) { status in
                let count = assessment.items.filter { $0.status == status }.count
                if count > 0 {
                    Label {
                        Text(AppLocalization.format(preflightCountKey(status), count))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: preflightItemSymbol(status))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(preflightItemColor(status))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityIdentifier("deliveryCheckSummary")
    }

    private func preflightCountKey(_ status: PDFDeliveryPreflightItemStatus) -> String {
        switch status {
        case .passed: return "%lld passed"
        case .willFix: return "%lld to fix"
        case .review: return "%lld to review"
        case .blocked: return "%lld blocked"
        }
    }

    private var preflightLoadingPanel: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.medium) {
                preflightLoadingIdentity
                Spacer(minLength: PPSpacing.small)
                preflightStopButton
            }
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                preflightLoadingIdentity
                preflightStopButton
            }
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityIdentifier("deliveryPreflightLoading")
    }

    private var preflightLoadingIdentity: some View {
        HStack(spacing: PPSpacing.small) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Checking on device".localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text("The private PDF stays on this device.".localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var preflightStopButton: some View {
        Button {
            stopPreflight()
        } label: {
            Label("Stop checking", systemImage: "stop.fill")
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
        .disabled(preflightTask == nil)
        .accessibilityHint(
            "Stops this check without changing the working copy."
                .localizedUI
        )
        .accessibilityIdentifier("stopDeliveryPreflight")
    }

    private var preflightStoppedPanel: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.medium) {
                preflightStoppedIdentity
                Spacer(minLength: PPSpacing.small)
                preflightRetryButton
            }
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                preflightStoppedIdentity
                preflightRetryButton
            }
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityIdentifier("deliveryPreflightStopped")
    }

    private var preflightStoppedIdentity: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("PDF check stopped".localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text("The working copy was not changed.".localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
        } icon: {
            Image(systemName: "pause.circle")
                .foregroundStyle(PPColor.amber)
        }
    }

    private var preflightRetryButton: some View {
        Button {
            retryPreflight()
        } label: {
            Label("Check Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
        .accessibilityHint(
            "Restarts the on-device check for the current PDF."
                .localizedUI
        )
        .accessibilityIdentifier("retryStoppedDeliveryPreflight")
    }

    private func startSafeShareCreation() {
        guard let preflight = currentPreflight,
              let preflightRevisionID,
              preflight.status != .blocked,
              preflightTask == nil,
              preflightReviewTask == nil
        else { return }
        let previousOutputID = model.verifiedShareTarget(
            for: recordID
        )?.id
        let generation = beginExport(label: "verified copy")
        exportTask = Task { @MainActor in
            defer {
                finishExport(generation)
            }
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createSafeShareCopy(
                    recordID: recordID,
                    expectedContentRevisionID:
                        preflightRevisionID
                )
            }
            guard exportGeneration == generation else { return }
            let committed = created
                ?? model.verifiedShareTarget(for: recordID)
                    .flatMap {
                        $0.id == previousOutputID ? nil : $0
                    }
            if exportStopRequested || Task.isCancelled {
                model[noticeFor: paperPathSceneID] = (
                    committed == nil
                        ? "Verification stopped · no output created"
                        : "Verification finished before stopping · output kept in Library"
                ).localizedUI
                return
            }
            guard exportIsCurrent(generation),
                  let created
            else { return }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }



    private func completePreparedOutputTransition() {
        guard let route = pendingPreparedRoute else { return }
        pendingPreparedRoute = nil
        transitioningPreparedRoute = route
        preparedOutputTransitionFeedback += 1
        preparedOutputTransitionTask?.cancel()
        let generation = UUID()
        preparedOutputTransitionGeneration = generation
        preparedOutputTransitionTask = Task { @MainActor in
            defer {
                if preparedOutputTransitionGeneration == generation {
                    preparedOutputTransitionTask = nil
                    transitioningPreparedRoute = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  preparedOutputTransitionGeneration == generation,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  model.record(id: route.recordID) != nil
            else { return }
            onCreated(route)
        }
    }

    private func cancelPreparedOutputTransition(
        showsNotice: Bool = false
    ) {
        preparedOutputTransitionGeneration = UUID()
        preparedOutputTransitionTask?.cancel()
        preparedOutputTransitionTask = nil
        pendingPreparedRoute = nil
        transitioningPreparedRoute = nil
        if showsNotice {
            model[noticeFor: paperPathSceneID] = "Export kept in export history"
                .localizedUI
        }
    }

    private func preflightItemsList(
        _ items: [PDFDeliveryPreflightItem]
    ) -> some View {
        let priorities: [PDFDeliveryPreflightItemStatus] = [.blocked, .review, .willFix, .passed]
        let ordered = priorities.flatMap { status in
            items.filter { $0.status == status }
        }
        return VStack(spacing: 0) {
            ForEach(
                Array(ordered.enumerated()),
                id: \.element.id
            ) { index, item in
                preflightRow(item)
                if index < ordered.count - 1 {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.55))
                        .frame(height: 0.6)
                        .padding(.leading, 32)
                }
            }
        }
    }

    private func preflightRow(
        _ item: PDFDeliveryPreflightItem
    ) -> some View {
        let isOpening = openingPreflightItemID == item.id
        return Group {
            if let pageIndex = item.reviewPageIndex {
                let layout = dynamicTypeSize.ppPrefersExpandedLayout
                    ? AnyLayout(
                        VStackLayout(
                            alignment: .leading,
                            spacing: PPSpacing.xSmall
                        )
                    )
                    : AnyLayout(
                        HStackLayout(
                            alignment: .top,
                            spacing: PPSpacing.small
                        )
                    )
                layout {
                    Button {
                        openPreflightReview(item)
                    } label: {
                        preflightRowContent(
                            item,
                            showsDisclosure: true,
                            isOpening: isOpening
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(preflightReviewTask != nil)
                    .accessibilityValue(
                        isOpening
                            ? "Opening issue action".localizedUI
                            : ""
                    )
                    .accessibilityHint(
                        (
                            preflightReviewTask == nil
                                ? AppLocalization.format(
                                    "Opens page %lld for review",
                                    pageIndex + 1
                                )
                                : "Wait for the current issue action to open."
                                    .localizedUI
                        )
                    )

                    if let repairAction = item.resolvedRepairAction {
                        preflightRepairButton(
                            item,
                            action: repairAction,
                            pageIndex: pageIndex
                        )
                    }
                }
            } else if let repairAction = item.resolvedRepairAction {
                let layout = dynamicTypeSize.ppPrefersExpandedLayout
                    ? AnyLayout(
                        VStackLayout(
                            alignment: .leading,
                            spacing: PPSpacing.xSmall
                        )
                    )
                    : AnyLayout(
                        HStackLayout(
                            alignment: .top,
                            spacing: PPSpacing.small
                        )
                    )
                layout {
                    preflightRowContent(
                        item,
                        showsDisclosure: false,
                        isOpening: isOpening
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    preflightRepairButton(
                        item,
                        action: repairAction,
                        pageIndex: nil
                    )
                }
            } else {
                preflightRowContent(
                    item,
                    showsDisclosure: false,
                    isOpening: false
                )
            }
        }
    }

    private func preflightRowContent(
        _ item: PDFDeliveryPreflightItem,
        showsDisclosure: Bool,
        isOpening: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Image(systemName: preflightItemSymbol(item.status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(preflightItemColor(item.status))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(item.detail.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if isOpening {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            } else if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                    .padding(.top, 5)
            }
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .combine)
    }

    private func preflightRepairButton(
        _ item: PDFDeliveryPreflightItem,
        action: PDFDeliveryPreflightRepairAction,
        pageIndex: Int?
    ) -> some View {
        Button {
            openPreflightRepair(item, action: action)
        } label: {
            Label(
                action.title.localizedUI,
                systemImage: action.symbol
            )
            .lineLimit(2)
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
        .disabled(preflightReviewTask != nil)
        .accessibilityHint(
            preflightRepairHint(
                action,
                pageIndex: pageIndex
            )
        )
        .accessibilityIdentifier("repairPreflightItem")
    }

    private func preflightRepairHint(
        _ action: PDFDeliveryPreflightRepairAction,
        pageIndex: Int?
    ) -> String {
        switch action {
        case .organizePages:
            guard let pageIndex else {
                return "Opens Pages for review.".localizedUI
            }
            return AppLocalization.format(
                "Opens Pages with page %lld selected",
                pageIndex + 1
            )
        case .createEditableCopy:
            return "Opens the secure password flow. The encrypted original stays unchanged."
                .localizedUI
        }
    }

    private var recoveryActions: some View {
        outputSection(
            title: "CONTINUE SAFELY",
            detail: "The working copy remains unchanged",
            symbol: "lifepreserver",
            tint: PPColor.amber
        ) {
            Button {
                preparePDFShare(
                    recordID: recordID,
                    label: "working copy"
                )
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open current copy in another app")
                            .foregroundStyle(PPColor.textPrimary)
                        Text(
                            "PaperPath keeps this working copy unchanged."
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                    }
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(PPColor.accent)
                }
            }
            .disabled(exportTask != nil)
            .accessibilityHint(
                "Prepare a temporary file for sharing"
            )
            .accessibilityIdentifier("shareBlockedWorkingCopy")

            Button {
                retryPreflight()
            } label: {
                Label("Check this PDF again", systemImage: "arrow.clockwise")
            }
            .disabled(
                preflightTask != nil
                    || preflightReviewTask != nil
                    || exportTask != nil
                    || model.isProcessing(recordID)
            )
            .accessibilityIdentifier("retryDeliveryPreflight")
        }
    }

    private var currentContentRevisionID: UUID? {
        model.record(id: recordID)?.contentRevisionID
    }

    private var currentPreflight: PDFDeliveryPreflightAssessment? {
        guard preflightRevisionID == currentContentRevisionID else {
            return nil
        }
        return preflight
    }

    private func startPreflightIfNeeded(
        force: Bool = false
    ) {
        guard activeFocus == .safeShare,
              preflightTask == nil,
              let revisionID = currentContentRevisionID,
              model.record(id: recordID)?
                .hasCurrentDeliveryReceipt != true
        else { return }
        if !force, currentPreflight != nil {
            return
        }
        preflightPaused = false
        preflight = nil
        preflightRevisionID = nil
        preflightError = nil
        let generation = UUID()
        preflightGeneration = generation
        preflightTask = Task { @MainActor in
            defer {
                if preflightGeneration == generation {
                    preflightTask = nil
                }
            }
            do {
                if let record = model.record(id: recordID),
                   record.taskCheckpoint?.stage != .verify
                    || record.taskCheckpoint?.contentRevisionID
                        != revisionID {
                    let checkpointSaved =
                        await model.updateTaskCheckpoint(
                            recordID: recordID,
                            checkpoint: DocumentTaskCheckpoint(
                                stage: .verify,
                                contentRevisionID: revisionID
                            ),
                            presentsFeedback: false
                        )
                    guard !Task.isCancelled,
                          preflightGeneration == generation,
                          currentContentRevisionID == revisionID
                    else { return }
                    if !checkpointSaved {
                        model[noticeFor: paperPathSceneID] =
                            "Resume point could not be saved"
                                .localizedUI
                    }
                }
                let assessment = try await model.withFeedbackTarget(
                    paperPathSceneID
                ) {
                    try await model.deliveryPreflight(
                        recordID: recordID
                    )
                }
                guard !Task.isCancelled,
                      preflightGeneration == generation,
                      currentContentRevisionID == revisionID
                else { return }
                preflight = assessment
                preflightRevisionID = revisionID
                preflightSuccessFeedback += 1
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      preflightGeneration == generation,
                      currentContentRevisionID == revisionID
                else { return }
                if let paperError = error as? PaperPathError,
                   case .lockedPDF = paperError {
                    preflightError =
                        "Unlock this PDF and remove its password first."
                } else {
                    preflightError =
                        "PaperPath could not reopen every page. The working copy was not changed."
                }
                preflightErrorFeedback += 1
            }
        }
    }

    private func retryPreflight() {
        cancelPreflightTask()
        preflightPaused = false
        startPreflightIfNeeded(force: true)
    }

    private func openPreflightReview(
        _ item: PDFDeliveryPreflightItem
    ) {
        beginPreflightHandoff(item) {
            pageIndex,
            checkpointSaved in
            onReviewPage(pageIndex, checkpointSaved)
        }
    }

    private func openPreflightRepair(
        _ item: PDFDeliveryPreflightItem,
        action: PDFDeliveryPreflightRepairAction
    ) {
        guard item.reviewPageIndex != nil else {
            beginPreflightHandoffWithoutPage(item) {
                onRepairPreflightItem(action, nil, true)
            }
            return
        }
        beginPreflightHandoff(item) {
            pageIndex,
            checkpointSaved in
            onRepairPreflightItem(
                action,
                pageIndex,
                checkpointSaved
            )
        }
    }

    private func beginPreflightHandoffWithoutPage(
        _ item: PDFDeliveryPreflightItem,
        completion: @escaping @MainActor () -> Void
    ) {
        guard preflightReviewTask == nil,
              let revisionID = currentContentRevisionID
        else { return }
        let generation = UUID()
        preflightReviewGeneration = generation
        openingPreflightItemID = item.id
        preflightReviewTask = Task { @MainActor in
            defer {
                if preflightReviewGeneration == generation {
                    preflightReviewTask = nil
                    openingPreflightItemID = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  preflightReviewGeneration == generation,
                  currentContentRevisionID == revisionID
            else { return }
            completion()
        }
    }

    private func beginPreflightHandoff(
        _ item: PDFDeliveryPreflightItem,
        completion: @escaping @MainActor (Int, Bool) -> Void
    ) {
        guard preflightReviewTask == nil,
              let pageIndex = item.reviewPageIndex,
              let revisionID = currentContentRevisionID
        else { return }

        let generation = UUID()
        preflightReviewGeneration = generation
        openingPreflightItemID = item.id
        preflightReviewTask = Task { @MainActor in
            defer {
                if preflightReviewGeneration == generation {
                    preflightReviewTask = nil
                    openingPreflightItemID = nil
                }
            }
            let checkpointSaved =
                await model.updateTaskCheckpoint(
                    recordID: recordID,
                    checkpoint: DocumentTaskCheckpoint(
                        stage: .verify,
                        pageIndex: pageIndex,
                        fieldName: item.title.localizedUI,
                        contentRevisionID: revisionID
                    ),
                    presentsFeedback: false
                )
            guard !Task.isCancelled,
                  preflightReviewGeneration == generation,
                  currentContentRevisionID == revisionID
            else { return }
            if !checkpointSaved {
                preflightReviewErrorFeedback += 1
            }
            completion(pageIndex, checkpointSaved)
        }
    }

    private func stopPreflightReviewHandoff(
        showNotice: Bool = true
    ) {
        guard preflightReviewTask != nil else { return }
        preflightReviewGeneration = UUID()
        preflightReviewTask?.cancel()
        preflightReviewTask = nil
        openingPreflightItemID = nil
        if showNotice {
            model[noticeFor: paperPathSceneID] =
                "Opening issue action stopped".localizedUI
        }
    }

    private func stopPreflight(
        showNotice: Bool = true
    ) {
        guard preflightTask != nil else { return }
        cancelPreflightTask()
        preflight = nil
        preflightRevisionID = nil
        preflightError = nil
        preflightPaused = true
        if showNotice {
            model[noticeFor: paperPathSceneID] = "PDF check stopped".localizedUI
        }
    }

    private func invalidatePreflight() {
        stopPreflightReviewHandoff(showNotice: false)
        cancelPreflightTask()
        preflight = nil
        preflightRevisionID = nil
        preflightError = nil
        preflightPaused = false
    }

    private func cancelPreflightTask() {
        preflightGeneration = UUID()
        preflightTask?.cancel()
        preflightTask = nil
    }

    private func preflightColor(
        _ status: PDFDeliveryPreflightStatus
    ) -> Color {
        switch status {
        case .ready: return PPColor.mint
        case .review: return PPColor.amber
        case .blocked: return Color.red
        }
    }

    private func preflightItemSymbol(
        _ status: PDFDeliveryPreflightItemStatus
    ) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .willFix: return "wand.and.stars"
        case .review: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private func preflightItemColor(
        _ status: PDFDeliveryPreflightItemStatus
    ) -> Color {
        switch status {
        case .passed: return PPColor.mint
        case .willFix: return PPColor.accent
        case .review: return PPColor.amber
        case .blocked: return Color.red
        }
    }

    private func exportButton(
        _ title: String,
        detail: String? = nil,
        symbol: String,
        badge: String? = nil,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: PPSpacing.small) {
                ToolSymbolPlate(
                    symbol: symbol,
                    tint: PPColor.accent,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    if let detail {
                        Text(detail.localizedUI)
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: PPSpacing.small)
                if let badge {
                    Text(badge)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(PPColor.accent)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
            }
            .padding(.horizontal, PPSpacing.small)
            .padding(.vertical, 5)
            .frame(minHeight: 50)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(PPColor.accent.opacity(0.62))
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
            .contentShape(Rectangle())
        }
        .disabled(
            model.isProcessing(recordID)
                || exportTask != nil
                || isPreparedOutputTransitionActive
                || temporaryOfficeResultURL != nil
        )
        .accessibilityIdentifier(
            identifier ?? "documentExport-\(title)"
        )
    }

    private func officeGuidedChoice(
        _ record: DocumentRecord,
        portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        let canReconstruct = !portfolio.isProtected

        return VStack(alignment: .leading, spacing: PPSpacing.medium) {
            officePageScope(record)
            Text("Output format".localizedUI)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(portfolio.plans) { plan in
                officeFormatSelection(plan, recommended: portfolio.recommendedPlan?.format == plan.format)
            }
            Text(officeCompatibilityLine(selectedOfficeFormat).localizedUI)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let limit = selectedOfficeFormat.officePageLimit,
               !usesOfficePageRange,
               record.profile.pageCount > limit,
               let batch = model.officeBatchPlan(recordID: recordID, format: selectedOfficeFormat) {
                Label(batch.summary.localizedUI, systemImage: "square.stack.3d.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !canReconstruct {
                Label(
                    "This PDF blocks editable conversion. Open an unlocked copy."
                        .localizedUI,
                    systemImage:
                        "lock.trianglebadge.exclamationmark"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, PPSpacing.xSmall)
                Button {
                    onCreated(DocumentRoute(
                        recordID: record.id,
                        expectedContentRevisionID: record.contentRevisionID
                    ))
                } label: {
                    Label("Open source PDF", systemImage: "lock.open")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
            }

            Button {
                withAnimation(
                    reduceMotion ? nil : .snappy(duration: 0.2)
                ) {
                    showsOfficeEvidence.toggle()
                }
            } label: {
                HStack {
                    Label(
                        showsOfficeEvidence
                            ? "Hide compatibility evidence"
                            : "Compatibility & audit details",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    Spacer()
                    Image(
                        systemName: showsOfficeEvidence
                            ? "chevron.up"
                            : "chevron.down"
                    )
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                showsOfficeEvidence ? "Expanded" : "Collapsed"
            )
        }
        .padding(.vertical, PPSpacing.xSmall)
        .onAppear {
            guard !didChooseOfficeFormat else { return }
            selectedOfficeFormat = portfolio.recommendedPlan?.format ?? .wordDocument
            didChooseOfficeFormat = true
        }
    }

    private func officePageScope(_ record: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Toggle("Convert a page range".localizedUI, isOn: $usesOfficePageRange)
                .font(.subheadline.weight(.semibold))
            if usesOfficePageRange {
                HStack(spacing: PPSpacing.regular) {
                    VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                        Text("First page".localizedUI).font(.caption)
                        TextField("First page".localizedUI, value: $officeFirstPage, format: .number.grouping(.never))
                            .accessibilityIdentifier("officeFirstPage")
                    }
                    VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                        Text("Last page".localizedUI).font(.caption)
                        TextField("Last page".localizedUI, value: $officeLastPage, format: .number.grouping(.never))
                            .accessibilityIdentifier("officeLastPage")
                    }
                }
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                if let error = officePageRangeError(record, format: selectedOfficeFormat) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(PPColor.amber)
                } else {
                    Text(AppLocalization.format(
                        "%lld pages selected", officeLastPage - officeFirstPage + 1
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                }
            } else {
                Text(AppLocalization.format("All pages (%lld)", record.profile.pageCount))
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .disabled(exportTask != nil || temporaryOfficeResultURL != nil)
    }

    private func officePageRangeError(
        _ record: DocumentRecord, format: PDFTextExportFormat
    ) -> String? {
        guard usesOfficePageRange else { return nil }
        guard officeFirstPage >= 1, officeFirstPage <= officeLastPage,
              officeLastPage <= record.profile.pageCount
        else {
            return AppLocalization.format(
                "Choose a range between page 1 and %lld.", record.profile.pageCount
            )
        }
        if let limit = format.officePageLimit, officeLastPage - officeFirstPage + 1 > limit {
            return AppLocalization.format("Select up to %lld pages for this format.", limit)
        }
        return nil
    }

    private func officeAlternativeChoice(
        _ plan: PDFOfficeExportFormatPlan,
        canReconstruct: Bool
    ) -> some View {
        Button {
            selectedOfficeFormat = plan.format
            didChooseOfficeFormat = true
            activeFocus = .text
        } label: {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: plan.format.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        officeReadinessColor(plan.readiness)
                    )
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.format.title.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    Text(officePurposeLine(plan.format).localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: PPSpacing.small)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(minHeight: 50)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.58))
                    .frame(height: 0.6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(
            !canReconstruct
                || model.isProcessing(recordID)
                || exportTask != nil
                || temporaryOfficeResultURL != nil
        )
        .accessibilityHint(
            officeCompatibilityLine(plan.format).localizedUI
        )
        .accessibilityIdentifier("recommendedOfficeExport")
    }

    private func officePurposeLine(
        _ format: PDFTextExportFormat
    ) -> String {
        switch format {
        case .wordDocument:
            return "Edit paragraphs, headings, and detected tables"
        case .excelWorkbook:
            return "Work with detected rows, values, and page sheets"
        case .powerPointPresentation:
            return "Keep each PDF page’s appearance on a slide"
        case .richText:
            return "Edit simple styled paragraphs"
        case .markdown:
            return "Move structured text into a knowledge base"
        case .plainText:
            return "Use the smallest, most compatible text file"
        }
    }

    private func officeCompatibilityLine(
        _ format: PDFTextExportFormat
    ) -> String {
        switch format {
        case .wordDocument:
            return "DOCX is rebuilt locally; complex layouts may reflow."
        case .excelWorkbook:
            return "XLSX layout is inferred; review complex tables."
        case .powerPointPresentation:
            return "PPTX keeps page appearance; slide content is not fully editable."
        case .richText:
            return "RTF keeps basic text styling without the original page layout."
        case .markdown, .plainText:
            return "Text output intentionally removes the original page layout."
        }
    }

    private func officeCommandCenter(
        _ record: DocumentRecord,
        portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        let confidence = portfolio.routeConfidence
        let sla = portfolio.productionSLA
        let budget = portfolio.visualBudgetPlan

        return VStack(alignment: .leading, spacing: PPSpacing.medium) {
            WorkflowCommandHeader(
                eyebrow: "OFFICE COMMAND CENTER",
                title: portfolio.decisionLine,
                detail: portfolio.decisionDeckLine,
                symbol: confidence.symbol,
                tint: officeConfidenceColor(confidence),
                metrics: [
                    WorkflowMetric(
                        value: portfolio.recommendedPlan?.format
                            .fileExtension
                            .uppercased() ?? "DOCX",
                        label: "Route",
                        symbol: "target",
                        tint: PPColor.accent
                    ),
                    WorkflowMetric(
                        value: confidence.title,
                        label: "Confidence",
                        symbol: confidence.symbol,
                        tint: officeConfidenceColor(confidence)
                    ),
                    WorkflowMetric(
                        value: sla.title,
                        label: "SLA",
                        symbol: sla.symbol,
                        tint: officeSLAColor(sla)
                    ),
                    WorkflowMetric(
                        value: "\(budget.estimatedBudgetUsePercent)%",
                        label: "Budget",
                        symbol: budget.budgetPressure.symbol,
                        tint: officeBudgetPressureColor(
                            budget.budgetPressure
                        )
                    )
                ]
            )

            officeRouteComparator(portfolio)
            officeAuditCoverageStrip(portfolio)
            officePrimaryCommand(portfolio)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: PPSpacing.medium) {
                    officeCommandLedger(portfolio)
                    officeRiskLedger(portfolio)
                }
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    officeCommandLedger(portfolio)
                    officeRiskLedger(portfolio)
                }
            }

            officeRecoveryRail(portfolio)
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppLocalization.format(
                "Office command center for %@",
                record.displayName
            )
        )
    }

    @ViewBuilder
    private func officePrimaryCommand(
        _ portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        if let plan = portfolio.recommendedPlan {
            let exceedsLimit = plan.format.officePageLimit.map {
                portfolio.pageCount > $0
            } ?? false
            let tint = officeReadinessColor(plan.readiness)
            Button {
                officeRouteFeedback += 1
                if exceedsLimit {
                    startOfficeBatch(plan.format)
                } else {
                    startTextExport(plan.format)
                }
            } label: {
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: plan.format.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.1), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            AppLocalization.format(
                                exceedsLimit
                                    ? "Export %@ as batch"
                                    : "Export recommended %@",
                                plan.format.fileExtension.uppercased()
                            )
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        Text(
                            AppLocalization.format(
                                "%@ · %@ · %@",
                                plan.decisionRole.localizedUI,
                                plan.compactEvidence,
                                portfolio.productionSLA.window
                                    .localizedUI
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: PPSpacing.small)
                    Text("\(plan.compositeScore)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(tint)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                }
                .padding(.horizontal, PPSpacing.small)
                .frame(minHeight: 44)
                .background(tint.opacity(0.07))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(tint)
                        .frame(width: 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                model.isProcessing(recordID)
                    || exportTask != nil
            )
            .accessibilityLabel(
                AppLocalization.format(
                    "Export recommended %@",
                    plan.format.fileExtension.uppercased()
                )
            )
        }
    }

    private func officeRouteComparator(
        _ portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        let plans = portfolio.plans
            .sorted { $0.compositeScore > $1.compositeScore }
        let recommendedID = portfolio.recommendedPlan?.id

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                ForEach(plans) { plan in
                    officeRouteComparatorToken(
                        plan,
                        isRecommended: plan.id == recommendedID
                    )
                }
            }
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                ForEach(plans) { plan in
                    officeRouteComparatorToken(
                        plan,
                        isRecommended: plan.id == recommendedID
                    )
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(portfolio.routeRankLine)
    }

    private func officeAuditCoverageStrip(
        _ portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.large) {
                    officeAuditMetric(
                        value: "3/3",
                        label: "File audit",
                        symbol: "checkmark.seal.fill",
                        tint: PPColor.mint
                    )
                    officeAuditMetric(
                        value: "\(portfolio.preflightSignals.count)",
                        label: "Preflight",
                        symbol: "checklist",
                        tint: PPColor.accent
                    )
                    officeAuditMetric(
                        value: "\(portfolio.pageCount)",
                        label: "Pages",
                        symbol: "doc.on.doc",
                        tint: PPColor.cyan
                    )
                    officeAuditMetric(
                        value: "LOCAL",
                        label: "Boundary",
                        symbol: "iphone",
                        tint: PPColor.mint
                    )
                }
                HStack(spacing: PPSpacing.medium) {
                    officeAuditMetric(
                        value: "3/3",
                        label: "File audit",
                        symbol: "checkmark.seal.fill",
                        tint: PPColor.mint
                    )
                    officeAuditMetric(
                        value: "\(portfolio.preflightSignals.count)",
                        label: "Preflight",
                        symbol: "checklist",
                        tint: PPColor.accent
                    )
                    officeAuditMetric(
                        value: "\(portfolio.pageCount)",
                        label: "Pages",
                        symbol: "doc.on.doc",
                        tint: PPColor.cyan
                    )
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        portfolio.visualBudgetPlan.chunkCount > 1
                            ? PPColor.amber
                            : PPColor.mint
                    )
                Text(portfolio.outputBoundaryLine.localizedUI)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.56))
                .frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.56))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppLocalization.format(
                "%@. %@",
                portfolio.embeddedAuditSummary,
                portfolio.outputBoundaryLine
            )
        )
    }

    private func officeAuditMetric(
        value: String,
        label: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.localizedUI)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Text(label.localizedUI)
                    .font(.caption2.smallCaps())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 72, alignment: .leading)
    }

    private func officeRouteComparatorToken(
        _ plan: PDFOfficeExportFormatPlan,
        isRecommended: Bool
    ) -> some View {
        let tint = officeReadinessColor(plan.readiness)

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: plan.format.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(plan.format.fileExtension.uppercased())
                            .font(.caption2.smallCaps().weight(.black))
                            .foregroundStyle(PPColor.textPrimary)
                        if isRecommended {
                            Text("BEST")
                                .font(.caption2.smallCaps().weight(.bold))
                                .foregroundStyle(tint)
                        }
                    }
                    Text(plan.decisionRole.localizedUI)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(plan.compositeScore)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(tint)
            }

            Text(plan.preferredUse.localizedUI)
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(2)

            officeRouteScoreStrip(plan, tint: tint)

            HStack(spacing: 5) {
                Image(
                    systemName: plan.fallbackFormat == nil
                        ? "checkmark.seal"
                        : "arrow.triangle.branch"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                Text(
                    plan.fallbackFormat.map {
                        AppLocalization.format(
                            "Fallback %@",
                            $0.fileExtension.uppercased()
                        )
                    } ?? plan.riskEvidence
                )
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 88)
        .background(
            isRecommended ? tint.opacity(0.08) : PPColor.surface.opacity(0.62)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(isRecommended ? 0.72 : 0.36))
                .frame(height: isRecommended ? 2 : 1)
        }
    }

    private func officeRouteScoreStrip(
        _ plan: PDFOfficeExportFormatPlan,
        tint: Color
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                officeRouteScore("E", value: plan.editabilityScore, tint: tint)
                officeRouteScore("A", value: plan.appearanceScore, tint: tint)
                officeRouteScore("S", value: plan.sizeScore, tint: tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                officeRouteScore("E", value: plan.editabilityScore, tint: tint)
                officeRouteScore("A", value: plan.appearanceScore, tint: tint)
                officeRouteScore("S", value: plan.sizeScore, tint: tint)
            }
        }
    }

    private func officeRouteScore(
        _ label: String,
        value: Int,
        tint: Color
    ) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
        }
        .padding(.horizontal, 5)
        .frame(minHeight: 18)
        .background(tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func officeCommandLedger(
        _ portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PPColor.accent)
                    .frame(width: 22, height: 22)
                    .background(PPColor.accent.opacity(0.09), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Route ledger".localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                    Text(portfolio.routeRankLine.localizedUI)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.medium) {
                    officeContract("Text", value: "\(portfolio.textCoveragePercent)%")
                    officeContract("Image", value: "\(portfolio.imageDominantPageCount)")
                    officeContract("Forms", value: "\(portfolio.formFieldCount)")
                    officeContract("Memory", value: portfolio.visualBudgetPlan.memoryGuardSummary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    officeContract("Text", value: "\(portfolio.textCoveragePercent)%")
                    officeContract("Image", value: "\(portfolio.imageDominantPageCount)")
                    officeContract("Forms", value: "\(portfolio.formFieldCount)")
                    officeContract("Memory", value: portfolio.visualBudgetPlan.memoryGuardSummary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PPColor.accent)
                .frame(width: 2)
        }
    }

    private func officeRiskLedger(
        _ portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        let risk = portfolio.primaryRiskSignal
        let readiness = risk?.readiness ?? .strong

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: risk?.symbol ?? "checkmark.seal.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(officeReadinessColor(readiness))
                    .frame(width: 22, height: 22)
                    .background(
                        officeReadinessColor(readiness).opacity(0.09),
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text((risk?.title ?? "Risk").localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                    Text((risk?.value ?? "Clear").localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(
                (risk?.detail ?? "No blocking Office export risk detected.")
                    .localizedUI
            )
            .font(.caption2)
            .foregroundStyle(PPColor.textSecondary)
            .lineLimit(2)
            officeContract("Preflight", value: portfolio.preflightSummary)
            officeContract("SLA", value: portfolio.productionSLA.detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(officeReadinessColor(readiness))
                .frame(width: 2)
        }
    }

    @ViewBuilder
    private func officeRecoveryRail(
        _ portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        if !portfolio.recoveryActions.isEmpty {
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                HStack(spacing: PPSpacing.small) {
                    SectionEyebrow(text: "NEXT BEST ACTIONS")
                    Text("\(portfolio.recoveryActions.count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(PPColor.accent)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        ForEach(portfolio.recoveryActions) { action in
                            officeRecoveryActionButton(action)
                        }
                    }
                    VStack(alignment: .leading, spacing: PPSpacing.small) {
                        ForEach(portfolio.recoveryActions) { action in
                            officeRecoveryActionButton(action)
                        }
                    }
                }
            }
        }
    }

    private func officeRecoveryActionButton(
        _ action: PDFOfficeRecoveryAction
    ) -> some View {
        let tint = officeReadinessColor(action.tintRole)

        return Button {
            officeRouteFeedback += 1
            if let targetFormat = action.targetFormat {
                startTextExport(targetFormat)
            } else if let targetQuickTask = action.targetQuickTask {
                onCreated(
                    DocumentRoute(
                        recordID: recordID,
                        quickTask: targetQuickTask
                    )
                )
            } else if action.id == "ocr" {
                onCreated(
                    DocumentRoute(
                        recordID: recordID,
                        quickTask: .recognizeText
                    )
                )
            } else {
                model[noticeFor: paperPathSceneID] = action.detail
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: action.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title.localizedUI)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Text(action.detail.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, PPSpacing.small)
            .frame(
                maxWidth: .infinity,
                minHeight: 46,
                alignment: .leading
            )
            .background(
                tint.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tint.opacity(0.45))
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isProcessing(recordID) || exportTask != nil)
    }

    private func officeExportProgressPanel(
        _ exportLabel: String,
        format: PDFTextExportFormat,
        record: DocumentRecord
    ) -> some View {
        let portfolio = PDFOfficeExportPortfolio(profile: record.profile)
        let plan = portfolio.plan(for: format)
        let progress = model.progress(for: recordID)
        let tint = officeReadinessColor(plan.readiness)

        return HStack(alignment: .top, spacing: PPSpacing.small) {
            if let progress {
                ProgressView(value: progress.fractionCompleted)
                    .tint(tint)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .tint(tint)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: PPSpacing.small) {
                    Text(
                        AppLocalization.format(
                            "Building %@",
                            format.fileExtension.uppercased()
                        )
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    if let progress {
                        Text("\(progress.percentCompleted)%")
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(tint)
                    }
                    Text(exportLabel.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                }
                officeExportStageStrip(
                    progress?.fractionCompleted ?? 0,
                    tint: tint
                )
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.medium) {
                        officeContract(
                            "Route",
                            value: portfolio.decisionLine
                        )
                        officeContract(
                            "Confidence",
                            value: portfolio.routeConfidence.title
                        )
                        officeContract(
                            "Budget",
                            value:
                                portfolio.visualBudgetPlan
                                .pressureContract
                        )
                        officeContract(
                            "Audit",
                            value: "File meta"
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        officeContract(
                            "Route",
                            value: portfolio.decisionLine
                        )
                        officeContract(
                            "Confidence",
                            value: portfolio.routeConfidence.title
                        )
                        officeContract(
                            "Budget",
                            value:
                                portfolio.visualBudgetPlan
                                .pressureContract
                        )
                        officeContract(
                            "Audit",
                            value: "File meta"
                        )
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppLocalization.format(
                "Preparing %@ on device",
                format.title.localizedUI
            )
        )
    }

    private func officeExportStageStrip(
        _ fractionCompleted: Double,
        tint: Color
    ) -> some View {
        let currentStage = PDFOfficeExportStage.current(
            fractionCompleted: fractionCompleted
        )
        return HStack(spacing: 5) {
            ForEach(
                Array(PDFOfficeExportStage.allCases.enumerated()),
                id: \.element.id
            ) {
                index,
                stage in
                let isReached =
                    fractionCompleted >= stage.threshold
                let isCurrent = stage == currentStage
                HStack(spacing: 3) {
                    Image(
                        systemName: isReached && !isCurrent
                            ? "checkmark.circle.fill"
                            : stage.symbol
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        isReached ? tint : PPColor.textSecondary
                    )
                    Text(stage.title.localizedUI)
                        .font(.caption2.smallCaps().weight(.semibold))
                        .foregroundStyle(
                            isReached
                                ? PPColor.textPrimary
                                : PPColor.textSecondary
                        )
                        .lineLimit(1)
                }
                if index
                    < PDFOfficeExportStage.allCases.count - 1 {
                    Rectangle()
                        .fill(
                            isReached
                                ? tint.opacity(0.55)
                                : PPColor.border.opacity(0.5)
                        )
                        .frame(maxWidth: 20)
                        .frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func officeExportFailurePanel(
        _ failure: PDFOfficeExportFailure,
        record: DocumentRecord
    ) -> some View {
        let format = failure.format
        let tint = failure.kind == .verification
            ? Color.red
            : PPColor.amber
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PPSpacing.small))
            : AnyLayout(HStackLayout(alignment: .top, spacing: PPSpacing.small))

        return layout {
            Image(systemName: failure.kind.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(failure.kind.title.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                Text(failure.detail.localizedUI)
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    AppLocalization.format(
                        "%@ · source unchanged · %@ pages",
                        format.fileExtension.uppercased(),
                        "\(record.profile.pageCount)"
                    )
                )
                .font(.caption2.smallCaps())
                .foregroundStyle(PPColor.textSecondary)
            }
            Spacer(minLength: PPSpacing.small)
            HStack(spacing: 4) {
                if failure.kind.allowsRetry {
                    Button {
                        officeFailure = nil
                        startTextExport(format)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        "Retry Office export".localizedUI
                    )
                }
                if let recoveryTask = failure.kind.recoveryTask {
                    Button {
                        openOfficeRecoveryTask(recoveryTask)
                    } label: {
                        Image(
                            systemName: recoveryTask == .splitPDF
                                ? "rectangle.split.3x1"
                                : "text.viewfinder"
                        )
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        failure.kind.title.localizedUI
                    )
                }
            }
            .disabled(exportTask != nil || model.isProcessing(recordID))
        }
        .padding(.vertical, 5)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 2)
        }
        .accessibilityElement(children: .contain)
    }

    private func officeReadinessStrip(
        _ record: DocumentRecord,
        portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.medium) {
                officePortfolioMetric(
                    "BEST",
                    value: portfolio.recommendedPlan?.format
                        .fileExtension
                        .uppercased() ?? "DOCX",
                    symbol: "target",
                    tint: PPColor.accent
                )
                officePortfolioMetric(
                    "TEXT",
                    value: "\(portfolio.textCoveragePercent)%",
                    symbol: "text.magnifyingglass",
                    tint: portfolio.textCoveragePercent >= 60
                        ? PPColor.mint
                        : PPColor.amber
                )
                officePortfolioMetric(
                    "IMAGE",
                    value: "\(portfolio.imageDominantPageCount)",
                    symbol: "photo.on.rectangle",
                    tint: portfolio.imageDominantPageCount == 0
                        ? PPColor.mint
                        : PPColor.cyan
                )
                officePortfolioMetric(
                    "FORMS",
                    value: "\(portfolio.formFieldCount)",
                    symbol: "list.bullet.clipboard",
                    tint: portfolio.formFieldCount == 0
                        ? PPColor.textSecondary
                        : PPColor.amber
                )
            }
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                HStack(spacing: PPSpacing.medium) {
                    officePortfolioMetric(
                        "BEST",
                        value: portfolio.recommendedPlan?.format
                            .fileExtension
                            .uppercased() ?? "DOCX",
                        symbol: "target",
                        tint: PPColor.accent
                    )
                    officePortfolioMetric(
                        "TEXT",
                        value: "\(portfolio.textCoveragePercent)%",
                        symbol: "text.magnifyingglass",
                        tint: portfolio.textCoveragePercent >= 60
                            ? PPColor.mint
                            : PPColor.amber
                    )
                }
                HStack(spacing: PPSpacing.medium) {
                    officePortfolioMetric(
                        "IMAGE",
                        value: "\(portfolio.imageDominantPageCount)",
                        symbol: "photo.on.rectangle",
                        tint: portfolio.imageDominantPageCount == 0
                            ? PPColor.mint
                            : PPColor.cyan
                    )
                    officePortfolioMetric(
                        "FORMS",
                        value: "\(portfolio.formFieldCount)",
                        symbol: "list.bullet.clipboard",
                        tint: portfolio.formFieldCount == 0
                            ? PPColor.textSecondary
                            : PPColor.amber
                    )
                }
            }
        }
        .padding(.vertical, 3)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(
                    portfolio.isProtected
                        ? PPColor.amber
                        : PPColor.accent
                )
                .frame(width: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppLocalization.format(
                "Office export readiness for %@",
                record.displayName
            )
        )
    }

    private func officePortfolioMetric(
        _ label: String,
        value: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.localizedUI)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Text(label.localizedUI)
                    .font(.caption2.smallCaps())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 72, alignment: .leading)
    }

    private func officeDecisionStrip(
        _ portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Image(systemName: portfolio.recommendedPlan?.readiness.symbol
                ?? "target")
                .font(.caption.weight(.bold))
                .foregroundStyle(
                    portfolio.recommendedPlan
                        .map { officeReadinessColor($0.readiness) }
                        ?? PPColor.accent
                )
                .frame(width: 24, height: 24)
                .background(
                    (portfolio.recommendedPlan
                        .map { officeReadinessColor($0.readiness) }
                        ?? PPColor.accent)
                        .opacity(0.1),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: PPSpacing.small) {
                    Text("Recommended route".localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                    Text(portfolio.decisionLine.localizedUI)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                }
                Text(portfolio.cautionLine.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(
                    portfolio.recommendedPlan
                        .map { officeReadinessColor($0.readiness) }
                        ?? PPColor.accent
                )
                .frame(width: 2)
        }
        .accessibilityElement(children: .combine)
    }

    private func officePreflightStrip(
        _ portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        officePreflightSignalsStrip(
            portfolio.preflightSignals,
            summary: portfolio.preflightSummary
        )
    }

    private func officePreflightSignalsStrip(
        _ signals: [PDFOfficePreflightSignal],
        summary: String
    ) -> some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    ForEach(signals) { signal in
                        officePreflightToken(signal)
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.medium) {
                        ForEach(signals) { signal in
                            officePreflightToken(signal)
                        }
                    }
                    VStack(alignment: .leading, spacing: PPSpacing.small) {
                        HStack(spacing: PPSpacing.medium) {
                            ForEach(
                                Array(signals.prefix(2))
                            ) { signal in
                                officePreflightToken(signal)
                            }
                        }
                        HStack(spacing: PPSpacing.medium) {
                            ForEach(
                                Array(signals.dropFirst(2))
                            ) { signal in
                                officePreflightToken(signal)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppLocalization.format(
                "Office preflight %@",
                summary.localizedUI
            )
        )
    }

    private func officePreflightToken(
        _ signal: PDFOfficePreflightSignal
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: signal.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(officeReadinessColor(signal.readiness))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(signal.value.localizedUI)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout ? nil : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
                Text(signal.title.localizedUI)
                    .font(.caption2.smallCaps())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout ? nil : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout
                ? nil
                : 86,
            maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                ? .infinity
                : nil,
            alignment: .leading
        )
        .help(signal.detail.localizedUI)
    }

    private func officeBudgetStrip(
        _ plan: PDFOfficeVisualBudgetPlan
    ) -> some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    officeBudgetToken(
                        "MODE",
                        value: plan.mode.title,
                        symbol: plan.mode.symbol,
                        tint: PPColor.accent
                    )
                    officeBudgetToken(
                        "PAGE",
                        value: plan.formattedPerPageBudget,
                        symbol: "doc.badge.gearshape",
                        tint: PPColor.cyan
                    )
                    officeBudgetToken(
                        "LADDER",
                        value: plan.compressionLadderSummary,
                        symbol: "slider.horizontal.below.rectangle",
                        tint: PPColor.mint
                    )
                    officeBudgetToken(
                        "PRESSURE",
                        value: plan.budgetPressure.title,
                        symbol: plan.budgetPressure.symbol,
                        tint: officeBudgetPressureColor(
                            plan.budgetPressure
                        )
                    )
                    officeBudgetToken(
                        "ANCHOR",
                        value: plan.anchorPolicy.title,
                        symbol: plan.anchorPolicy.symbol,
                        tint: PPColor.accent
                    )
                    officeBudgetToken(
                        "WINDOW",
                        value: plan.reserveWindowSummary,
                        symbol: "rectangle.stack.badge.plus",
                        tint: PPColor.cyan
                    )
                    officeBudgetToken(
                        "VISUAL",
                        value: "\(plan.estimatedVisualReferencePages)",
                        symbol: "photo.stack",
                        tint: plan.estimatedVisualReferencePages == 0
                            ? PPColor.textSecondary
                            : PPColor.amber
                    )
                    officeBudgetToken(
                        "PACKAGE",
                        value: plan.chunkSummary,
                        symbol: "shippingbox",
                        tint: plan.chunkCount <= 1
                            ? PPColor.mint
                            : PPColor.amber
                    )
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.medium) {
                        officeBudgetToken(
                            "MODE",
                            value: plan.mode.title,
                            symbol: plan.mode.symbol,
                            tint: PPColor.accent
                        )
                        officeBudgetToken(
                            "PAGE",
                            value: plan.formattedPerPageBudget,
                            symbol: "doc.badge.gearshape",
                            tint: PPColor.cyan
                        )
                        officeBudgetToken(
                            "LADDER",
                            value: plan.compressionLadderSummary,
                            symbol: "slider.horizontal.below.rectangle",
                            tint: PPColor.mint
                        )
                        officeBudgetToken(
                            "PRESSURE",
                            value: plan.budgetPressure.title,
                            symbol: plan.budgetPressure.symbol,
                            tint: officeBudgetPressureColor(
                                plan.budgetPressure
                            )
                        )
                        officeBudgetToken(
                            "ANCHOR",
                            value: plan.anchorPolicy.title,
                            symbol: plan.anchorPolicy.symbol,
                            tint: PPColor.accent
                        )
                        officeBudgetToken(
                            "WINDOW",
                            value: plan.reserveWindowSummary,
                            symbol: "rectangle.stack.badge.plus",
                            tint: PPColor.cyan
                        )
                        officeBudgetToken(
                            "VISUAL",
                            value: "\(plan.estimatedVisualReferencePages)",
                            symbol: "photo.stack",
                            tint: plan.estimatedVisualReferencePages == 0
                                ? PPColor.textSecondary
                                : PPColor.amber
                        )
                        officeBudgetToken(
                            "PACKAGE",
                            value: plan.chunkSummary,
                            symbol: "shippingbox",
                            tint: plan.chunkCount <= 1
                                ? PPColor.mint
                                : PPColor.amber
                        )
                    }
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        HStack(spacing: PPSpacing.medium) {
                            officeBudgetToken(
                                "MODE",
                                value: plan.mode.title,
                                symbol: plan.mode.symbol,
                                tint: PPColor.accent
                            )
                            officeBudgetToken(
                                "PAGE",
                                value: plan.formattedPerPageBudget,
                                symbol: "doc.badge.gearshape",
                                tint: PPColor.cyan
                            )
                        }
                        HStack(spacing: PPSpacing.medium) {
                            officeBudgetToken(
                                "LADDER",
                                value: plan.compressionLadderSummary,
                                symbol:
                                    "slider.horizontal.below.rectangle",
                                tint: PPColor.mint
                            )
                            officeBudgetToken(
                                "PRESSURE",
                                value: plan.budgetPressure.title,
                                symbol: plan.budgetPressure.symbol,
                                tint: officeBudgetPressureColor(
                                    plan.budgetPressure
                                )
                            )
                        }
                        HStack(spacing: PPSpacing.medium) {
                            officeBudgetToken(
                                "ANCHOR",
                                value: plan.anchorPolicy.title,
                                symbol: plan.anchorPolicy.symbol,
                                tint: PPColor.accent
                            )
                            officeBudgetToken(
                                "WINDOW",
                                value: plan.reserveWindowSummary,
                                symbol: "rectangle.stack.badge.plus",
                                tint: PPColor.cyan
                            )
                        }
                        HStack(spacing: PPSpacing.medium) {
                            officeBudgetToken(
                                "VISUAL",
                                value:
                                    "\(plan.estimatedVisualReferencePages)",
                                symbol: "photo.stack",
                                tint:
                                    plan.estimatedVisualReferencePages == 0
                                        ? PPColor.textSecondary
                                        : PPColor.amber
                            )
                            officeBudgetToken(
                                "PACKAGE",
                                value: plan.chunkSummary,
                                symbol: "shippingbox",
                                tint: plan.chunkCount <= 1
                                    ? PPColor.mint
                                    : PPColor.amber
                            )
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppLocalization.format(
                "Office visual budget %@, %@, %@ per visual reference",
                plan.mode.title.localizedUI,
                plan.anchorPolicy.title.localizedUI,
                plan.formattedPerPageBudget
            )
        )
    }

    private func officeBudgetToken(
        _ label: String,
        value: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.localizedUI)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout ? nil : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
                Text(label.localizedUI)
                    .font(.caption2.smallCaps())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout ? nil : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout
                ? nil
                : 82,
            maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                ? .infinity
                : nil,
            alignment: .leading
        )
    }

    private func officeBudgetPressureColor(
        _ pressure: PDFOfficeVisualBudgetPressure
    ) -> Color {
        switch pressure {
        case .relaxed:
            return PPColor.mint
        case .managed:
            return PPColor.cyan
        case .tight:
            return PPColor.amber
        }
    }

    private func officeConfidenceColor(
        _ confidence: PDFOfficeRouteConfidence
    ) -> Color {
        switch confidence {
        case .high:
            return PPColor.mint
        case .guarded:
            return PPColor.amber
        case .weak:
            return Color.red
        }
    }

    private func officeSLAColor(
        _ sla: PDFOfficeProductionSLA
    ) -> Color {
        switch sla {
        case .quick:
            return PPColor.mint
        case .steady:
            return PPColor.cyan
        case .heavy:
            return PPColor.amber
        case .constrained:
            return Color.red
        }
    }

    private func officeReceiptPanel(
        _ receipt: PDFOfficeExportReceipt,
        record: DocumentRecord
    ) -> some View {
        let availability = receipt.artifactAvailability(
            for: record.contentRevisionID
        )
        return HStack(
            alignment: .top,
            spacing: PPSpacing.small
        ) {
            Image(systemName: receipt.routeConfidence.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(officeConfidenceColor(receipt.routeConfidence))
                .frame(width: 26, height: 26)
                .background(
                    officeConfidenceColor(receipt.routeConfidence)
                        .opacity(0.1),
                    in: Circle()
                )
                .symbolEffect(
                    .bounce,
                    value: reduceMotion ? 0 : officeReceiptFeedback
                )
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: PPSpacing.small) {
                    Text(receipt.fileName.localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Text(receipt.shortTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(receipt.qualityGateSummary.localizedUI)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Text(receipt.auditEvidenceSummary.localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(
                            receipt.leadPreflightSignal
                                .map {
                                    officeReadinessColor($0.readiness)
                                }
                                ?? PPColor.textSecondary
                        )
                        .lineLimit(1)
                }
                if let batchSummary = receipt.batchSummary {
                    Label(
                        batchSummary.localizedUI,
                        systemImage: "square.stack.3d.down.right"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PPColor.cyan)
                }
                if let evidence = receipt.runtimeEvidence {
                    Text(
                        AppLocalization.format(
                            "%@ · %lld %@",
                            evidence.yieldSummary,
                            evidence.primaryUnitCount,
                            evidence.primaryUnitLabel.localizedUI
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.large) {
                        officeContract(
                            "Confidence",
                            value: receipt.routeConfidence.title
                        )
                        officeContract(
                            "Size",
                            value: receipt.formattedSize
                        )
                        officeContract(
                            "Score",
                            value: "\(receipt.routeScore)"
                        )
                        officeContract(
                            "Budget",
                            value: receipt.budgetContractSummary
                        )
                        officeContract(
                            "Visual",
                            value: "\(receipt.visualReferenceEstimate)"
                        )
                        officeContract(
                            "Evidence",
                            value: receipt.embeddedEvidenceLabel
                        )
                        officeContract(
                            "Integrity",
                            value: receipt.shortArtifactFingerprint
                                ?? "Pending"
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        officeContract(
                            "Confidence",
                            value: receipt.routeConfidence.title
                        )
                        officeContract(
                            "Size",
                            value: receipt.formattedSize
                        )
                        officeContract(
                            "Score",
                            value: "\(receipt.routeScore)"
                        )
                        officeContract(
                            "Budget",
                            value: receipt.budgetContractSummary
                        )
                        officeContract(
                            "Visual",
                            value: "\(receipt.visualReferenceEstimate)"
                        )
                        officeContract(
                            "Evidence",
                            value: receipt.embeddedEvidenceLabel
                        )
                        officeContract(
                            "Integrity",
                            value: receipt.shortArtifactFingerprint
                                ?? "Pending"
                        )
                    }
                }
                if !receipt.preflightSignals.isEmpty {
                    officePreflightSignalsStrip(
                        receipt.preflightSignals,
                        summary: receipt.preflightSummary
                    )
                    if let lead = receipt.leadPreflightSignal {
                        Text(lead.detail.localizedUI)
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: availability.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            availability == .reusable
                                ? PPColor.mint
                                : PPColor.amber
                        )
                    Text(availability.title.localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                    Text(receipt.retentionSummary.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            officeReceiptMenu(
                receipt,
                availability: availability
            )
        }
        .padding(.vertical, 5)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(officeReadinessColor(receipt.readiness))
                .frame(width: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppLocalization.format(
                "Office export %@, %@, %@",
                receipt.format.title.localizedUI,
                receipt.receiptSummary.localizedUI,
                receipt.embeddedEvidenceLabel.localizedUI
            )
        )
    }

    @ViewBuilder
    private func officeReceiptHistory(
        record: DocumentRecord,
        currentReceiptID: UUID?
    ) -> some View {
        let recent = record.officeReceipts
            .filter { $0.id != currentReceiptID }
            .prefix(3)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: PPSpacing.small) {
                    Label(
                        "Recent Office outputs".localizedUI,
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                    Text("\(record.officeReceipts.count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(PPColor.accent)
                }
                ForEach(Array(recent)) { receipt in
                    officeReceiptHistoryRow(
                        receipt,
                        record: record
                    )
                }
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .contain)
        }
    }

    private func officeReceiptHistoryRow(
        _ receipt: PDFOfficeExportReceipt,
        record: DocumentRecord
    ) -> some View {
        let availability = receipt.artifactAvailability(
            for: record.contentRevisionID
        )
        return HStack(
            alignment: .center,
            spacing: PPSpacing.small
        ) {
            Image(systemName: receipt.format.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(officeConfidenceColor(receipt.routeConfidence))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(receipt.format.fileExtension.uppercased())
                        .font(.caption2.smallCaps().weight(.black))
                        .foregroundStyle(PPColor.textPrimary)
                        .frame(width: 34, alignment: .leading)
                    Text(receipt.qualityGateSummary.localizedUI)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(receipt.shortTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.medium) {
                        officeContract(
                            "Confidence",
                            value: receipt.routeConfidence.title
                        )
                        officeContract("Size", value: receipt.formattedSize)
                        officeContract(
                            "Budget",
                            value: receipt.budgetContractSummary
                        )
                        officeContract(
                            "Evidence",
                            value: receipt.embeddedEvidenceLabel
                        )
                    }
                    Text(receipt.auditEvidenceSummary.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                }
                if let batchSummary = receipt.batchSummary {
                    Text(batchSummary.localizedUI)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(PPColor.cyan)
                        .lineLimit(1)
                }
            }
            officeReceiptMenu(
                receipt,
                availability: availability
            )
        }
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(
                    officeConfidenceColor(receipt.routeConfidence)
                        .opacity(0.7)
                )
                .frame(width: 1)
                .offset(x: -4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppLocalization.format(
                "Recent Office export %@, %@, %@",
                receipt.format.title.localizedUI,
                receipt.receiptSummary.localizedUI,
                receipt.embeddedEvidenceLabel.localizedUI
            )
        )
    }

    private func officeReceiptMenu(
        _ receipt: PDFOfficeExportReceipt,
        availability: PDFOfficeArtifactAvailability
    ) -> some View {
        Menu {
            Button {
                shareRetainedOfficeExport(receipt, previewing: true)
            } label: {
                Label("Preview output", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(availability != .reusable)

            Button {
                inspectedOfficeReceipt = receipt
            } label: {
                Label(
                    "View conversion checks",
                    systemImage: "checklist.checked"
                )
            }

            Button {
                shareRetainedOfficeExport(receipt)
            } label: {
                Label(
                    "Share Office output",
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(availability != .reusable)

            Divider()

            Button {
                toggleOfficeExportPinned(receipt)
            } label: {
                Label(
                    receipt.isPinned
                        ? "Unpin Office output"
                        : "Pin Office output",
                    systemImage: receipt.isPinned
                        ? "pin.slash"
                        : "pin"
                )
            }
            .disabled(
                availability != .reusable
                    && !receipt.isPinned
            )
        } label: {
            Image(
                systemName: receipt.isPinned
                    ? "pin.fill"
                    : "ellipsis.circle"
            )
            .foregroundStyle(
                receipt.isPinned
                    ? PPColor.cyan
                    : (
                        availability == .reusable
                            ? PPColor.mint
                            : PPColor.textSecondary
                    )
            )
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .disabled(
            exportTask != nil
                || officeGovernanceTask != nil
        )
        .accessibilityLabel("Office output actions".localizedUI)
    }

    private func toggleOfficeExportPinned(
        _ receipt: PDFOfficeExportReceipt
    ) {
        guard officeGovernanceTask == nil else { return }
        officeGovernanceTask = Task { @MainActor in
            defer {
                officeGovernanceTask = nil
            }
            await model.setOfficeExportPinned(
                recordID: recordID,
                receiptID: receipt.id,
                pinned: !receipt.isPinned
            )
            guard !Task.isCancelled else { return }
            if officeReceipt?.id == receipt.id {
                officeReceipt = model.record(id: recordID)?
                    .officeReceipts
                    .first { $0.id == receipt.id }
            }
            officePinFeedback += 1
        }
    }

    private func batchActionLabel(
        format: PDFTextExportFormat,
        pageCount: Int
    ) -> String {
        guard let record = model.record(id: recordID) else {
            return "BATCH"
        }
        let plan = PDFOfficeBatchPlan(
            format: format,
            sourceRevisionID: record.contentRevisionID,
            profile: record.profile
        )
        return AppLocalization.format(
            "%lld PARTS",
            plan.segmentCount
        )
    }

    private func startOfficeBatch(
        _ format: PDFTextExportFormat
    ) {
        guard exportTask == nil,
              !model.isProcessing(recordID),
              temporaryOfficeResultURL == nil,
              let revision = currentContentRevisionID
        else { return }
        selectedOfficeFormat = format
        didChooseOfficeFormat = true
        officeResultNotice = nil
        selectedBatchRetrySegmentIDs = []
        isShowingAllOfficeBatchSegments = false
        officeFailure = nil
        officeReceipt = nil
        let generation = beginExport(
            label: "\(format.title.lowercased()) batch",
            officeFormat: format
        )
        exportTask = Task { @MainActor in
            defer {
                finishExport(generation)
            }
            do {
#if DEBUG
                let usesUITestCancellationWindow =
                    ProcessInfo.processInfo.arguments.contains(
                        "UITEST_OFFICE_SOAK_DEMO"
                    )

                if usesUITestCancellationWindow {
                    try await Task.sleep(for: .seconds(20))
                }
#endif

                guard let run = try await model.makeOfficeBatch(
                    recordID: recordID,
                    format: format,
                    expectedSourceRevisionID: revision
                ) else {
                    guard exportIsCurrent(generation) else { return }
                    officeFailure = PDFOfficeExportFailure(
                        format: format,
                        kind: .unknown,
                        detail:
                            "This PDF is no longer available for segmented export."
                    )
                    officeFailureFeedback += 1
                    return
                }
                guard exportIsCurrent(generation) else {
                    if exportGeneration == generation, scenePhase == .active {
                        officeReceipt = model.record(id: recordID)?.officeReceipts.first { $0.batchID == run.id }
                        officeResultNotice = "Conversion stopped. Completed parts remain in local history."
                    }
                    return
                }
                if run.completedCount > 0 {
                    officeReceipt = model.record(id: recordID)?
                        .officeReceipts
                        .first { $0.batchID == run.id }
                    officeReceiptFeedback += 1
                } else if run.status != .cancelled {
                    officeFailure = PDFOfficeExportFailure(
                        format: format,
                        kind: .unknown,
                        detail: run.segments
                            .compactMap(\.failureDetail)
                            .first
                            ?? "No batch segment completed."
                    )
                    officeFailureFeedback += 1
                }
            } catch is CancellationError {
                return
            } catch {
                guard exportIsCurrent(generation) else { return }
                officeFailure = .classify(
                    format: format,
                    error: error
                )
                officeFailureFeedback += 1
            }
        }
    }

    private func retryOfficeBatch(
        _ run: PDFOfficeBatchRun
    ) {
        guard exportTask == nil,
              !model.isProcessing(recordID)
        else { return }
        let retryable = run.retryableSegmentIDs
        let selected = selectedBatchRetrySegmentIDs
            .intersection(retryable)
        let targetIDs = selected.isEmpty ? retryable : selected
        guard !targetIDs.isEmpty else { return }

        officeFailure = nil
        let generation = beginExport(
            label: AppLocalization.format(
                "retrying %lld Office part%@",
                targetIDs.count,
                targetIDs.count == 1 ? "" : "s"
            ),
            officeFormat: run.plan.format
        )
        exportTask = Task { @MainActor in
            defer {
                if exportGeneration == generation {
                    selectedBatchRetrySegmentIDs = []
                }
                finishExport(generation)
            }
            do {
                guard let result = try await model.resumeOfficeBatch(
                    recordID: recordID,
                    selectedSegmentIDs: targetIDs
                ) else {
                    guard exportIsCurrent(generation) else { return }
                    officeFailure = PDFOfficeExportFailure(
                        format: run.plan.format,
                        kind: .sourceChanged,
                        detail:
                            "This batch no longer matches the current PDF. Start a new export."
                    )
                    officeFailureFeedback += 1
                    return
                }
                guard exportIsCurrent(generation) else { return }
                if result.completedCount > 0 {
                    officeReceipt = model.record(id: recordID)?
                        .officeReceipts
                        .first { $0.batchID == result.id }
                    officeReceiptFeedback += 1
                }
            } catch is CancellationError {
                return
            } catch {
                guard exportIsCurrent(generation) else { return }
                officeFailure = .classify(
                    format: run.plan.format,
                    error: error
                )
                officeFailureFeedback += 1
            }
        }
    }

    private func shareOfficeBatch(
        _ run: PDFOfficeBatchRun
    ) {
        guard exportTask == nil,
              !model.isProcessing(recordID)
        else { return }
        let officeGeneration = beginOfficeSharePreparation(
            label: "Verifying protected Office files"
        )
        let taskGeneration = beginExport(
            label: "protected Office files"
        )
        exportTask = Task { @MainActor in
            defer {
                finishExport(taskGeneration)
                finishOfficeSharePreparation(
                    generation: officeGeneration
                )
            }
            let receiptIDs = Set(
                run.segments.compactMap(\.receiptID)
            )
            let receipts = model.record(id: recordID)?
                .officeReceipts
                .filter { receiptIDs.contains($0.id) }
                .sorted {
                    ($0.batchSegmentIndex ?? 0)
                        < ($1.batchSegmentIndex ?? 0)
                } ?? []
            guard receipts.count == run.completedCount else {
                guard exportIsCurrent(taskGeneration) else { return }
                officeFailure = .unavailableArtifact(
                    format: run.plan.format
                )
                officeFailureFeedback += 1
                return
            }
            let receiptCount = receipts.count
            let urls = await model
                .prepareReusableOfficeExportShareCopies(
                recordID: recordID,
                receiptIDs: receipts.map(\.id)
            ) { update in
                guard officeShareGeneration == officeGeneration else {
                    return
                }
                let completedFiles = min(
                    receiptCount,
                    update.completedUnitCount / 3
                )
                let visibleIndex = min(
                    receiptCount,
                    completedFiles
                        + (completedFiles < receiptCount ? 1 : 0)
                )
                publishOfficeShareProgress(
                    update,
                    label: AppLocalization.format(
                        "Verifying Office file %lld of %lld",
                        visibleIndex,
                        receiptCount
                    ),
                    generation: officeGeneration
                )
            }
            guard officeShareGeneration == officeGeneration,
                  exportIsCurrent(taskGeneration)
            else {
                if let urls {
                    await model.discardTemporaryExportCopies(
                        at: urls
                    )
                }
                return
            }
            guard let urls,
                  !urls.isEmpty
            else {
                if let urls {
                    await model.discardTemporaryExportCopies(
                        at: urls
                    )
                }
                guard exportIsCurrent(taskGeneration) else { return }
                officeFailure = .unavailableArtifact(
                    format: run.plan.format
                )
                officeFailureFeedback += 1
                return
            }
            share(urls, temporaryURLs: urls)
        }
    }

    private func shareOfficeBatchArchive(
        _ run: PDFOfficeBatchRun
    ) {
        guard exportTask == nil,
              !model.isProcessing(recordID)
        else { return }
        let generation = beginExport(label: "signed batch ZIP")
        exportTask = Task { @MainActor in
            defer {
                finishExport(generation)
            }
            do {
                let delivery = try await model.makeOfficeBatchArchive(
                    recordID: recordID,
                    batchID: run.id
                )
                guard exportIsCurrent(generation) else {
                    await model.discardTemporaryExportCopies(
                        at: [delivery.archive, delivery.report]
                    )
                    return
                }
                share(
                    [delivery.archive, delivery.report],
                    temporaryURLs: [
                        delivery.archive,
                        delivery.report
                    ]
                )
            } catch is CancellationError {
                return
            } catch {
                guard exportIsCurrent(generation) else { return }
                officeFailure = .classify(
                    format: run.plan.format,
                    error: error
                )
                officeFailureFeedback += 1
            }
        }
    }

    private func officeBatchRunPanel(
        _ run: PDFOfficeBatchRun,
        record: DocumentRecord
    ) -> some View {
        let tint = officeBatchStatusColor(run.status)
        let visibleSegments = visibleOfficeBatchSegments(run)
        let retryableIDs = run.retryableSegmentIDs
        let canRetry = record.contentRevisionID
                == run.plan.sourceRevisionID
            && !retryableIDs.isEmpty
            && run.status != .running
            && run.status != .preparing
        let selectedRetryCount = selectedBatchRetrySegmentIDs
            .intersection(retryableIDs)
            .count
        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                Image(
                    systemName: run.isFinished
                        ? (
                            run.completedCount > 0
                                ? "checkmark.seal.fill"
                                : "xmark.octagon.fill"
                        )
                        : "square.stack.3d.down.right"
                )
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.1), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(run.status.title.localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    Text(
                        AppLocalization.format(
                            "%@ · %@ · source %@",
                            run.plan.format.fileExtension.uppercased(),
                            run.plan.summary,
                            (
                                record.contentRevisionID
                                    == run.plan.sourceRevisionID
                                    ? "current"
                                    : "changed"
                            ).localizedUI
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text("\(run.percentCompleted)%")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(tint)
            }

            ProgressView(value: run.fractionCompleted)
                .tint(tint)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.large) {
                    officeContract(
                        "Ready",
                        value: "\(run.completedCount)"
                    )
                    officeContract(
                        "Failed",
                        value: "\(run.failedCount)"
                    )
                    officeContract(
                        "Parts",
                        value: "\(run.segments.count)"
                    )
                    officeContract(
                        "Retention",
                        value: "7 days"
                    )
                    if canRetry {
                        officeContract(
                            "Resume",
                            value: "\(retryableIDs.count)"
                        )
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    officeContract(
                        "Ready",
                        value: "\(run.completedCount)"
                    )
                    officeContract(
                        "Failed",
                        value: "\(run.failedCount)"
                    )
                    officeContract(
                        "Parts",
                        value: "\(run.segments.count)"
                    )
                    officeContract(
                        "Retention",
                        value: "7 days"
                    )
                    if canRetry {
                        officeContract(
                            "Resume",
                            value: "\(retryableIDs.count)"
                        )
                    }
                }
            }

            VStack(spacing: 0) {
                ForEach(visibleSegments) { segment in
                    officeBatchSegmentRow(
                        segment,
                        canSelect: canRetry
                            && retryableIDs.contains(segment.id),
                        isSelected: selectedBatchRetrySegmentIDs
                            .contains(segment.id)
                    )
                }
                if visibleSegments.count < run.segments.count {
                    Button {
                        isShowingAllOfficeBatchSegments = true
                    } label: {
                        Label(
                            AppLocalization.format(
                                "Show all %lld parts",
                                run.segments.count
                            ),
                            systemImage: "chevron.down"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PPColor.accent)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 44,
                            alignment: .leading
                        )
                    }
                    .buttonStyle(.plain)
                } else if isShowingAllOfficeBatchSegments,
                          run.segments.count > 8 {
                    Button {
                        isShowingAllOfficeBatchSegments = false
                    } label: {
                        Label(
                            "Show active parts only",
                            systemImage: "chevron.up"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PPColor.accent)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 44,
                            alignment: .leading
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if run.isFinished || canRetry {
                HStack(spacing: PPSpacing.small) {
                    if canRetry {
                        Button {
                            retryOfficeBatch(run)
                        } label: {
                            Label(
                                selectedRetryCount > 0
                                    ? AppLocalization.format(
                                        "Retry %lld selected",
                                        selectedRetryCount
                                    )
                                    : AppLocalization.format(
                                        "Resume %lld part%@",
                                        retryableIDs.count,
                                        retryableIDs.count == 1 ? "" : "s"
                                    ),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                        .disabled(exportTask != nil)
                    } else {
                        Button {
                            shareOfficeBatchArchive(run)
                        } label: {
                            Label(
                                run.completedCount == run.segments.count
                                    ? "Signed ZIP"
                                    : "Signed partial ZIP",
                                systemImage: "checkmark.shield"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                        .disabled(
                            run.completedCount == 0
                                || exportTask != nil
                        )
                        .accessibilityHint(
                            "Shares a ZIP plus an independently verifiable Ed25519 report."
                                .localizedUI
                        )
                    }

                    Menu {
                        Button {
                            shareOfficeBatch(run)
                        } label: {
                            Label(
                                "Share separate files",
                                systemImage: "doc.on.doc"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        run.completedCount == 0
                            || exportTask != nil
                    )
                    .accessibilityLabel("More delivery options")
                    .accessibilityHint(
                        "Shares verified Office files without the signed ZIP wrapper."
                            .localizedUI
                    )

                    Spacer(minLength: 0)

                    if run.isFinished {
                        Button {
                            clearFinishedOfficeBatch()
                        } label: {
                            Group {
                                if officeGovernanceTask != nil {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "xmark")
                                }
                            }
                            .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .disabled(
                            exportTask != nil
                                || officeGovernanceTask != nil
                        )
                        .accessibilityLabel(
                            "Dismiss batch summary".localizedUI
                        )
                    }
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppLocalization.format(
                "%@, %lld of %lld parts ready",
                run.status.title.localizedUI,
                run.completedCount,
                run.segments.count
            )
        )
    }

    private func clearFinishedOfficeBatch() {
        guard officeGovernanceTask == nil,
              exportTask == nil
        else { return }
        officeGovernanceTask = Task { @MainActor in
            defer {
                officeGovernanceTask = nil
            }
            await model.clearFinishedOfficeBatch(
                recordID: recordID
            )
        }
    }

    private func officeBatchSegmentRow(
        _ result: PDFOfficeBatchSegmentResult,
        canSelect: Bool,
        isSelected: Bool
    ) -> some View {
        let tint: Color
        switch result.status {
        case .completed:
            tint = PPColor.mint
        case .failed:
            tint = Color.red
        case .cancelled:
            tint = PPColor.textSecondary
        case .queued, .extracting, .rebuilding, .retaining:
            tint = PPColor.cyan
        }
        return Button {
            guard canSelect else { return }
            if isSelected {
                selectedBatchRetrySegmentIDs.remove(result.id)
            } else {
                selectedBatchRetrySegmentIDs.insert(result.id)
            }
            officeRouteFeedback += 1
        } label: {
            HStack(spacing: PPSpacing.small) {
                Image(
                    systemName: canSelect
                        ? (
                            isSelected
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        : result.status.symbol
                )
                .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        isSelected ? PPColor.accent : tint
                    )
                    .frame(width: 16)
                Text("P\(result.segment.index + 1)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.textPrimary)
                    .frame(width: 26, alignment: .leading)
                Text(result.segment.pageRangeLabel.localizedUI)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: PPSpacing.small)
                Text(
                    result.failureDetail?.localizedUI
                        ?? result.status.title.localizedUI
                )
                .font(.caption2)
                .foregroundStyle(
                    result.status == .failed
                        ? Color.red
                        : PPColor.textSecondary
                )
                .lineLimit(1)
                if ![
                       PDFOfficeBatchSegmentStatus.completed,
                       .failed,
                       .cancelled
                   ].contains(result.status) {
                    Text(
                        "\(Int((result.fractionCompleted * 100).rounded()))%"
                    )
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.42))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func visibleOfficeBatchSegments(
        _ run: PDFOfficeBatchRun
    ) -> [PDFOfficeBatchSegmentResult] {
        guard run.segments.count > 8,
              !isShowingAllOfficeBatchSegments
        else { return run.segments }
        var selected: [PDFOfficeBatchSegmentResult] = []
        let priority = run.segments.filter {
            $0.status == .failed
                || $0.status == .cancelled
                || $0.status == .extracting
                || $0.status == .rebuilding
                || $0.status == .retaining
        } + Array(
            run.segments.filter {
                $0.status == .completed
            }.suffix(3)
        ) + Array(
            run.segments.filter {
                $0.status == .queued
            }.prefix(3)
        )
        var seen: Set<UUID> = []
        for result in priority where seen.insert(result.id).inserted {
            selected.append(result)
            if selected.count == 8 { break }
        }
        return selected.sorted {
            $0.segment.index < $1.segment.index
        }
    }

    private func officeBatchStatusColor(
        _ status: PDFOfficeBatchStatus
    ) -> Color {
        switch status {
        case .preparing, .running:
            return PPColor.cyan
        case .paused:
            return PPColor.amber
        case .completed:
            return PPColor.mint
        case .partial:
            return PPColor.amber
        case .failed:
            return Color.red
        case .cancelled:
            return PPColor.textSecondary
        }
    }

    private func officeReadinessColor(
        _ readiness: PDFOfficeExportReadiness
    ) -> Color {
        switch readiness {
        case .strong:
            return PPColor.mint
        case .review:
            return PPColor.amber
        case .limited:
            return Color.red
        }
    }

    private func officeFormatButton(
        _ format: PDFTextExportFormat,
        plan: PDFOfficeExportFormatPlan?,
        sourcePageCount: Int,
        isRecommended: Bool
    ) -> some View {
        let requiresSplit = format.officePageLimit
            .map { sourcePageCount > $0 } ?? false
        let readinessColor = plan
            .map { officeReadinessColor($0.readiness) }
            ?? PPColor.accent
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                officeRouteFeedback += 1
                if requiresSplit {
                    startOfficeBatch(format)
                } else {
                    startTextExport(format)
                }
            } label: {
                HStack(alignment: .top, spacing: PPSpacing.small) {
                    ToolSymbolPlate(
                        symbol: format.symbol,
                        tint: readinessColor,
                        size: 38
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: PPSpacing.small) {
                                officeFormatHeader(
                                    format: format,
                                    plan: plan,
                                    requiresSplit: requiresSplit,
                                    isRecommended: isRecommended,
                                    sourcePageCount: sourcePageCount
                                )
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                officeFormatHeader(
                                    format: format,
                                    plan: plan,
                                    requiresSplit: requiresSplit,
                                    isRecommended: isRecommended,
                                    sourcePageCount: sourcePageCount
                                )
                            }
                        }
                        Text(
                            (plan?.preferredUse ?? format.bestFor)
                                .localizedUI
                        )
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(2)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: PPSpacing.large) {
                                officeContract(
                                    "Role",
                                    value: plan?.decisionRole
                                        ?? format.fileExtension.uppercased()
                                )
                                officeContract(
                                    "Edit",
                                    value: format.editabilityIntent
                                )
                                officeContract(
                                    "Appearance",
                                    value: format.appearanceIntent
                                )
                                officeContract(
                                    "Audit",
                                    value: "Embedded"
                                )
                                if let limit = format.officePageLimit {
                                    officeContract(
                                        "Limit",
                                        value: "\(limit)p"
                                    )
                                }
                                if let plan {
                                    officeContract(
                                        "Score",
                                        value: "\(plan.compositeScore)"
                                    )
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                officeContract(
                                    "Role",
                                    value: plan?.decisionRole
                                        ?? format.fileExtension.uppercased()
                                )
                                officeContract(
                                    "Edit",
                                    value: format.editabilityIntent
                                )
                                officeContract(
                                    "Appearance",
                                    value: format.appearanceIntent
                                )
                                officeContract(
                                    "Audit",
                                    value: "Embedded"
                                )
                                if let limit = format.officePageLimit {
                                    officeContract(
                                        "Limit",
                                        value: "\(limit)p"
                                    )
                                }
                                if let plan {
                                    officeContract(
                                        "Score",
                                        value: "\(plan.compositeScore)"
                                    )
                                }
                            }
                        }
                        if let plan {
                            Text(
                                AppLocalization.format(
                                    "%@ · %@",
                                    plan.riskEvidence.localizedUI,
                                    plan.compactEvidence
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                            .lineLimit(1)
                        }
                    }
                    Spacer(minLength: PPSpacing.small)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(
                            (
                                requiresSplit
                                    ? batchActionLabel(
                                        format: format,
                                        pageCount: sourcePageCount
                                    )
                                    : plan?.actionTitle ?? "Export"
                            ).localizedUI
                        )
                            .font(.caption2.smallCaps().weight(.bold))
                            .foregroundStyle(readinessColor)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(
                            isRecommended
                                ? readinessColor
                                : PPColor.border.opacity(0.6)
                        )
                        .frame(width: isRecommended ? 3 : 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let fallback = plan?.fallbackFormat {
                officeFallbackButton(
                    current: format,
                    fallback: fallback,
                    sourcePageCount: sourcePageCount,
                    readinessColor: readinessColor
                )
            }
        }
        .disabled(
            model.isProcessing(recordID)
                || exportTask != nil
        )
        .accessibilityHint(
            AppLocalization.format(
                "Exports %@ locally",
                format.title.localizedUI
            )
        )
    }

    @ViewBuilder
    private func officeFormatHeader(
        format: PDFTextExportFormat,
        plan: PDFOfficeExportFormatPlan?,
        requiresSplit: Bool,
        isRecommended: Bool,
        sourcePageCount: Int
    ) -> some View {
        Text(format.title.localizedUI)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PPColor.textPrimary)
            .lineLimit(1)
        Text(format.fileExtension.uppercased())
            .font(.caption2.smallCaps().weight(.bold))
            .foregroundStyle(PPColor.accent)
        if isRecommended {
            Text("BEST".localizedUI)
                .font(.caption2.smallCaps().weight(.black))
                .foregroundStyle(PPColor.mint)
        }
        if requiresSplit {
            Text(
                batchActionLabel(
                    format: format,
                    pageCount: sourcePageCount
                ).localizedUI
            )
                .font(.caption2.smallCaps().weight(.black))
                .foregroundStyle(PPColor.cyan)
        }
        if let plan {
            Label(
                plan.readiness.title.localizedUI,
                systemImage: plan.readiness.symbol
            )
            .font(.caption2.smallCaps().weight(.bold))
            .foregroundStyle(
                officeReadinessColor(plan.readiness)
            )
            .labelStyle(.titleAndIcon)
        }
    }

    private func officeFallbackButton(
        current: PDFTextExportFormat,
        fallback: PDFTextExportFormat,
        sourcePageCount: Int,
        readinessColor: Color
    ) -> some View {
        let fallbackRequiresSplit = fallback.officePageLimit
            .map { sourcePageCount > $0 } ?? false
        return Button {
            officeRouteFeedback += 1
            if fallbackRequiresSplit {
                startOfficeBatch(fallback)
            } else {
                startTextExport(fallback)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(readinessColor)
                    .frame(width: 14)
                Text(
                    AppLocalization.format(
                        "If %@ is weak, use %@ for this source",
                        current.fileExtension.uppercased(),
                        fallback.fileExtension.uppercased()
                    ).localizedUI
                )
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 52)
            .padding(.trailing, 6)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func officeContract(
        _ label: String,
        value: String
    ) -> some View {
        HStack(spacing: 3) {
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps())
                .foregroundStyle(PPColor.textSecondary)
            Text(value.localizedUI)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
        }
    }

    private func startTextExport(
        _ format: PDFTextExportFormat
    ) {
        guard exportTask == nil,
              !model.isProcessing(recordID),
              temporaryOfficeResultURL == nil,
              let record = model.record(id: recordID)
        else { return }
        let profile = record.profile
        let revision = record.contentRevisionID
        let usesRange = format.isOfficeFormat && usesOfficePageRange
        if usesRange, let error = officePageRangeError(record, format: format) {
            officeResultNotice = error
            return
        }
        let pageRange = usesRange ? (officeFirstPage - 1)...(officeLastPage - 1) : nil
        if !usesRange, format.officePageLimit.map({
            profile.pageCount > $0
        }) == true {
            startOfficeBatch(format)
            return
        }
        selectedOfficeFormat = format
        didChooseOfficeFormat = true
        officeResultNotice = nil
        let taskGeneration = beginExport(
            label: format.title.lowercased(),
            officeFormat: format.isOfficeFormat
                ? format
                : nil
        )
        exportTask = Task { @MainActor in
            if format.isOfficeFormat {
                officeReceipt = nil
                officeFailure = nil
            }
            defer {
                finishExport(taskGeneration)
            }
            do {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains(
                    "UITEST_OFFICE_SOAK_DEMO"
                ) {
                    try await Task.sleep(for: .seconds(20))
                }
#endif
                let artifact = try await model.makeTextExport(
                    recordID: recordID,
                    format: format,
                    expectedContentRevisionID: revision,
                    pageRange: pageRange
                )
                guard exportIsCurrent(taskGeneration) else {
                    await model.discardTemporaryExportCopies(
                        at: [artifact.url]
                    )
                    return
                }
                guard format.isOfficeFormat else {
                    share(
                        [artifact.url],
                        temporaryURLs: [artifact.url]
                    )
                    return
                }
                let size = (
                    try? artifact.url.resourceValues(
                        forKeys: [.fileSizeKey]
                    ).fileSize
                ) ?? 0
                let exportStem = record.displayName
                    .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
                    .joined(separator: "-")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". ")
                        .union(.whitespacesAndNewlines))
                let portfolio = PDFOfficeExportPortfolio(profile: artifact.sourceProfile)
                let plan = portfolio.plan(for: format)
                let budgetPlan = portfolio.visualBudgetPlan
                let rangeSuffix = pageRange.map { "-pages-\($0.lowerBound + 1)-\($0.upperBound + 1)" } ?? ""
                var receipt = PDFOfficeExportReceipt(
                    format: format,
                    fileName: "\(String((exportStem.isEmpty ? "Document" : exportStem).prefix(60)))\(rangeSuffix).\(format.fileExtension)",
                    fileSizeBytes: Int64(size),
                    plan: plan,
                    budgetPlan: budgetPlan,
                    portfolio: portfolio,
                    runtimeEvidence: artifact.runtimeEvidence
                )
                receipt.sourceRevisionID = revision
                receipt.sourcePageStartIndex = pageRange?.lowerBound
                receipt.sourcePageEndIndex = pageRange?.upperBound
                let retained = await model.retainOfficeExport(
                    recordID: recordID,
                    receipt: receipt,
                    sourceURL: artifact.url,
                    expectedContentRevisionID: revision
                )
                guard exportIsCurrent(taskGeneration) else {
                    if retained == nil {
                        await model.discardTemporaryExportCopies(
                            at: [artifact.url]
                        )
                    } else if exportGeneration == taskGeneration,
                              scenePhase == .active {
                        officeReceipt = retained?.receipt
                        officeResultNotice = "A completed output was kept in local history."
                    }
                    return
                }
                officeReceipt = retained?.receipt ?? receipt
                officeReceiptFeedback += 1
                if retained == nil {
                    temporaryOfficeResultURL = artifact.url
                    officeResultNotice = currentContentRevisionID == revision
                        ? "Output still available. Free space, retry, or share before closing."
                        : "The source PDF changed. This output belongs to the earlier revision."
                }
            } catch is CancellationError {
                if exportGeneration == taskGeneration, scenePhase == .active {
                    officeResultNotice = "Conversion stopped. The source PDF is unchanged."
                }
                return
            } catch {
                guard exportIsCurrent(taskGeneration) else { return }
                if format.isOfficeFormat {
                    officeFailure = .classify(
                        format: format,
                        error: error
                    )
                } else {
                    model.presentErrorMessage(
                        AppLocalization.userFacingErrorDescription(error),
                        in: paperPathSceneID
                    )
                }
                officeFailureFeedback += 1
            }
        }
    }

    private func shareRetainedOfficeExport(
        _ receipt: PDFOfficeExportReceipt,
        previewing: Bool = false
    ) {
        guard exportTask == nil,
              !model.isProcessing(recordID),
              temporaryOfficeResultURL == nil
        else { return }
        let officeGeneration = beginOfficeSharePreparation(
            label: "Verifying protected Office copy"
        )
        let taskGeneration = beginExport(
            label: "protected Office copy"
        )
        exportTask = Task { @MainActor in
            defer {
                finishExport(taskGeneration)
                finishOfficeSharePreparation(
                    generation: officeGeneration
                )
            }
            let url = await model
                .prepareReusableOfficeExportShareCopy(
                recordID: recordID,
                receiptID: receipt.id
            ) { update in
                publishOfficeShareProgress(
                    update,
                    label: "Verifying protected Office copy",
                    generation: officeGeneration
                )
            }
            guard officeShareGeneration == officeGeneration,
                  exportIsCurrent(taskGeneration)
            else {
                if let url {
                    await model.discardTemporaryExportCopies(
                        at: [url]
                    )
                }
                return
            }
            guard let url else {
                guard exportIsCurrent(taskGeneration) else { return }
                officeFailure = .unavailableArtifact(
                    format: receipt.format
                )
                officeFailureFeedback += 1
                return
            }
            if previewing {
                cleanupOfficePreview()
                officePreviewCopyURL = url
                officePreviewFile = OfficePreviewFile(url: url)
            } else {
                share([url], temporaryURLs: [url])
            }
        }
    }

    private func openOfficeRecoveryTask(
        _ quickTask: PDFQuickTask
    ) {
        officeFailure = nil
        onCreated(
            DocumentRoute(
                recordID: recordID,
                quickTask: quickTask,
                expectedContentRevisionID: currentContentRevisionID
            )
        )
    }

    private func pageImageBadge(
        _ preset: PDFPageImageExportPreset
    ) -> String {
        switch preset {
        case .jpegHigh, .jpegCompact:
            return "JPG"
        case .png:
            return "PNG"
        }
    }

    private func share(
        _ items: [Any],
        temporaryURLs: [URL] = [],
        preservesTemporaryResult: Bool = false
    ) {
        cleanupTemporaryExports()
        shareItems = items
        preservesSharedTemporaryResult = preservesTemporaryResult
        temporaryShareURLs = temporaryURLs
        isSharing = true
    }

    private func cleanupTemporaryExports() {
        let urls = temporaryShareURLs
        temporaryShareURLs = []
        shareItems = []
        guard !urls.isEmpty else { return }
        Task {
            await model.discardTemporaryExportCopies(at: urls)
        }
    }

    private func beginOfficeSharePreparation(
        label: String
    ) -> UUID {
        let generation = UUID()
        officeShareGeneration = generation
        officeShareRateWindow.reset()
        officeShareProgress = PDFOperationProgress(
            label: label,
            fractionCompleted: 0,
            byteStage: .checksumming
        )
        return generation
    }

    private func publishOfficeShareProgress(
        _ update: PDFByteProgressUpdate,
        label: String,
        generation: UUID
    ) {
        guard officeShareGeneration == generation else { return }
        if let progress = officeShareRateWindow.operationProgress(
            label: label,
            update: update,
            current: officeShareProgress
        ) {
            officeShareProgress = progress
        }
    }

    private func finishOfficeSharePreparation(
        generation: UUID
    ) {
        guard officeShareGeneration == generation else { return }
        officeShareGeneration = UUID()
        officeShareProgress = nil
        officeShareRateWindow.reset()
    }

    private func preparePDFShare(
        recordID targetRecordID: UUID,
        label: String,
        toFiles: Bool = false
    ) {
        guard exportTask == nil else { return }
        let pdfGeneration = UUID()
        pdfShareGeneration = pdfGeneration
        let taskGeneration = beginExport(label: label)
        exportTask = Task { @MainActor in
            pdfShareRateWindow.reset()
            pdfShareProgress = PDFOperationProgress(
                label: "Verifying protected share copy",
                fractionCompleted: 0,
                byteStage: .checksumming
            )
            defer {
                finishExport(taskGeneration)
                if pdfShareGeneration == pdfGeneration {
                    pdfShareProgress = nil
                    pdfShareRateWindow.reset()
                }
            }
            let preparedURL = await model.makeFilesExportCopy(
                recordID: targetRecordID
            ) { update in
                guard pdfShareGeneration == pdfGeneration else {
                    return
                }
                if let progress = pdfShareRateWindow.operationProgress(
                    label: "Verifying protected share copy",
                    update: update,
                    current: pdfShareProgress
                ) {
                    pdfShareProgress = progress
                }
            }
            guard let url = preparedURL else { return }
            guard exportIsCurrent(taskGeneration),
                  pdfShareGeneration == pdfGeneration
            else {
                await model.discardFilesExportCopy(at: url)
                return
            }
            if toFiles {
                temporaryShareURLs.append(url)
                filesExportURL = url
            } else {
                share([url], temporaryURLs: [url])
            }
        }
    }

    private func beginExport(
        label: String,
        officeFormat: PDFTextExportFormat? = nil
    ) -> UUID {
        let generation = UUID()
        exportGeneration = generation
        exportLabel = label
        activeOfficeFormat = officeFormat
        exportStopRequested = false
        return generation
    }

    private func exportIsCurrent(_ generation: UUID) -> Bool {
        exportGeneration == generation
            && !Task.isCancelled
            && scenePhase == .active
            && UIApplication.shared.isProtectedDataAvailable
    }

    private func finishExport(_ generation: UUID) {
        guard exportGeneration == generation else { return }
        exportTask = nil
        exportLabel = nil
        activeOfficeFormat = nil
        exportStopRequested = false
    }

    private func stopExportPreparation(
        invalidateResult: Bool = false
    ) {
        guard exportTask != nil else { return }
        if invalidateResult {
            exportGeneration = UUID()
            exportStopRequested = false
        } else {
            guard !exportStopRequested else { return }
            exportStopRequested = true
        }
        exportTask?.cancel()
        if invalidateResult {
            pdfShareGeneration = UUID()
            pdfShareProgress = nil
            pdfShareRateWindow.reset()
            officeShareGeneration = UUID()
            officeShareProgress = nil
            officeShareRateWindow.reset()
            exportTask = nil
            exportLabel = nil
            activeOfficeFormat = nil
        }
    }
}

private struct OfficePreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct OfficeExportPresentationSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}

private struct OfficeOutputPreview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let file: OfficePreviewFile

    var body: some View {
        NavigationStack {
            Group {
                if QLPreviewController.canPreview(file.url as NSURL) {
                    OfficeQuickLookController(url: file.url)
                } else {
                    ContentUnavailableView(
                        "Preview unavailable".localizedUI,
                        systemImage: "doc.questionmark",
                        description: Text("The saved output is still available to share.".localizedUI)
                    )
                }
            }
            .navigationTitle("Preview output".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close".localizedUI) { dismiss() }
                }
            }
            .overlay {
                if scenePhase != .active {
                    PPColor.canvas.ignoresSafeArea()
                }
            }
        }
        .privacySensitive()
        .modifier(OfficeExportPresentationSizing())
    }
}

private struct OfficeQuickLookController: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController, previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct OfficeInlineOutputPreview: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("privacy.hideLibraryPreviews") private var hidesPreviews = false
    @State private var previewURL: URL?
    @State private var loading = false
    @State private var protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
    @State private var retry = 0

    let recordID: UUID
    let revisionID: UUID
    let receipt: PDFOfficeExportReceipt
    let onOpen: () -> Void

    private var permitsPreview: Bool {
        !hidesPreviews && scenePhase == .active && protectedDataAvailable
    }

    private var permitsAutomaticPreview: Bool {
        receipt.fileSizeBytes > 0 && receipt.fileSizeBytes <= 32 * 1_024 * 1_024
    }

    private var previewStatus: String {
        if hidesPreviews { return "Preview hidden" }
        if !permitsAutomaticPreview { return "Open full preview" }
        if loading { return "Preparing preview" }
        if previewURL != nil && permitsPreview { return "Output preview ready" }
        return "Preview unavailable"
    }

    private var identity: String {
        "\(receipt.id)-\(revisionID)-\(permitsPreview)-\(retry)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PPColor.documentStage
                if permitsPreview, let previewURL {
                    OfficeQuickLookController(url: previewURL)
                        .id(previewURL)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    VStack(spacing: PPSpacing.small) {
                        if loading && permitsPreview {
                            ProgressView()
                            Text("Preparing preview".localizedUI)
                        } else {
                            Image(systemName: hidesPreviews ? "eye.slash" : receipt.format.symbol)
                                .font(.system(size: 28, weight: .regular))
                            Text(previewStatus.localizedUI)
                        }
                    }
                    .font(PPType.metadata)
                    .foregroundStyle(PPColor.textSecondary)
                }
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 150 : 210)
            .clipped()
            HStack {
                Label("Output preview".localizedUI, systemImage: "doc.viewfinder")
                    .font(PPType.metadata)
                    .foregroundStyle(PPColor.textSecondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(
                        previewStatus.localizedUI
                    )
                    .accessibilityIdentifier(
                        "officeOutputPreviewStatus"
                    )
                Spacer()
                if previewURL == nil, permitsPreview, permitsAutomaticPreview, !loading {
                    Button { retry += 1 } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Retry preview".localizedUI)
                }
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18))
                        .frame(width: 44, height: 44)
                }
                .disabled(loading || !permitsPreview)
                .accessibilityLabel("Preview output".localizedUI)
                .accessibilityIdentifier("officeOpenOutputPreview")
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .task(id: identity) { await loadPreview() }
        .onDisappear { clear() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clear() }
        }
        .onChange(of: revisionID) { _, _ in clear() }
        .onChange(of: hidesPreviews) { _, hidden in
            if hidden { clear() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification
        )) { _ in
            protectedDataAvailable = false
            clear()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification
        )) { _ in protectedDataAvailable = true }
        .privacySensitive()
    }

    private func clear() {
        if let previewURL {
            Task { await model.discardTemporaryExportCopies(at: [previewURL]) }
        }
        previewURL = nil
        loading = false
    }

    @MainActor
    private func loadPreview() async {
        clear()
        let generation = identity
        guard permitsPreview, permitsAutomaticPreview,
              model.record(id: recordID)?.contentRevisionID == revisionID
        else { return }
        loading = true
        guard let url = await model.prepareReusableOfficeExportShareCopy(
            recordID: recordID, receiptID: receipt.id
        ) else {
            if identity == generation { loading = false }
            return
        }
        guard !Task.isCancelled, permitsPreview, identity == generation else {
            await model.discardTemporaryExportCopies(at: [url])
            return
        }
        if !Task.isCancelled, permitsPreview, identity == generation,
           model.record(id: recordID)?.contentRevisionID == revisionID,
           QLPreviewController.canPreview(url as NSURL) {
            previewURL = url
            loading = false
            return
        }
        if identity == generation { loading = false }
        await model.discardTemporaryExportCopies(at: [url])
    }
}

private struct OfficeNoticeDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : PPMotion.selection) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: PPSpacing.small) {
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PPColor.textSecondary)
                        .frame(width: 24)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue((configuration.isExpanded ? "Expanded" : "Collapsed").localizedUI)
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct OfficeContentNoticesView: View {
    let receipt: PDFOfficeExportReceipt
    var compact = false

    private func summary(_ notice: PDFOfficeContentNotice) -> String {
        switch notice.kind {
        case .wordReconstruction: return "Numbering and page layout need review"
        case .spreadsheetTextOnly: return "Charts, images and conditional formatting not included"
        case .slideImages: return "Page images, not editable slide objects"
        case .pagesWithoutText: return "Pages without extracted text"
        case .missingVisualReferences: return "Page reference images not included"
        case .inferredTableLayout: return "Table positions need review"
        }
    }

    private func details(_ notice: PDFOfficeContentNotice) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Text(notice.kind.detail.localizedUI)
                .font(PPType.metadata)
                .foregroundStyle(PPColor.textSecondary)
            if let pages = notice.pageSummary(offset: receipt.sourcePageStartIndex ?? 0) {
                Text(pages)
                    .font(PPType.measure)
                    .foregroundStyle(PPColor.textPrimary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("officeNotice-\(notice.id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            ForEach(receipt.contentNotices) { notice in
                if compact {
                    DisclosureGroup {
                        details(notice).padding(.vertical, PPSpacing.small)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: PPSpacing.small) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(PPColor.amber)
                            VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                                Text(summary(notice).localizedUI)
                                    .font(.subheadline)
                                    .foregroundStyle(PPColor.textPrimary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !notice.pageIndices.isEmpty {
                                    Text(AppLocalization.format("%lld source pages", notice.pageIndices.count))
                                        .font(PPType.measure)
                                        .foregroundStyle(PPColor.textSecondary)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .tint(PPColor.textSecondary)
                    .disclosureGroupStyle(OfficeNoticeDisclosureStyle())
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("officeNoticeDetails-\(notice.id)")
                    Divider()
                } else {
                VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                    Label(notice.kind.title.localizedUI, systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.amber)
                    Text(notice.kind.detail.localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                    if let pages = notice.pageSummary(offset: receipt.sourcePageStartIndex ?? 0) {
                        Text(pages)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PPColor.textPrimary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("officeNotice-\(notice.id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct OfficeEvidenceInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let receipt: PDFOfficeExportReceipt
    let currentRevisionID: UUID?

    var body: some View {
        NavigationStack {
            List {
                if !receipt.contentNotices.isEmpty {
                    Section("Review converted content".localizedUI) {
                        OfficeContentNoticesView(receipt: receipt)
                    }
                }

                if let evidence = receipt.runtimeEvidence {
                    Section("Runtime yield") {
                        evidenceGrid(evidence)
                        runtimeSummary(evidence)
                    }

                    Section("Package resources") {
                        resourceGrid(evidence)
                    }
                } else {
                    Section("Runtime yield") {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Receipt predates runtime evidence")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(PPColor.textPrimary)
                                Text(
                                    "Route and preflight evidence remain available below."
                                )
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(PPColor.amber)
                        }
                    }
                }

                if let batchSummary = receipt.batchSummary {
                    Section("Batch lineage") {
                        Label(
                            batchSummary.localizedUI,
                            systemImage: "square.stack.3d.down.right"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.cyan)
                        evidenceKeyValue(
                            "Batch ID",
                            value: receipt.batchID?
                                .uuidString
                                .prefix(12)
                                .description ?? "Unavailable"
                        )
                    }
                }

                Section("Route contract") {
                    evidenceKeyValue(
                        "Decision",
                        value: receipt.routeSummary
                    )
                    evidenceKeyValue(
                        "Quality gate",
                        value: receipt.qualityGateSummary
                    )
                    evidenceKeyValue(
                        "Budget",
                        value: receipt.budgetContractSummary
                    )
                    evidenceKeyValue(
                        "Preflight",
                        value: receipt.preflightSummary
                    )
                }

                if !receipt.preflightSignals.isEmpty {
                    Section("Preflight evidence") {
                        ForEach(receipt.preflightSignals) { signal in
                            preflightRow(signal)
                        }
                    }
                }

                Section("Artifact") {
                    evidenceKeyValue(
                        "File",
                        value: receipt.fileName
                    )
                    evidenceKeyValue(
                        "Size",
                        value: receipt.formattedSize
                    )
                    evidenceKeyValue(
                        "Integrity",
                        value: receipt.integritySummary
                    )
                    evidenceKeyValue(
                        "Created",
                        value: receipt.exportedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    evidenceKeyValue(
                        "Retention",
                        value: receipt.retentionSummary
                    )
                    if let currentRevisionID {
                        let availability = receipt.artifactAvailability(
                            for: currentRevisionID
                        )
                        Label(
                            availability.title.localizedUI,
                            systemImage: availability.symbol
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            availability == .reusable
                                ? PPColor.mint
                                : PPColor.amber
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PPColor.canvas)
            .navigationTitle("Conversion details".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private var confidenceColor: Color {
        switch receipt.routeConfidence {
        case .high:
            return PPColor.mint
        case .guarded:
            return PPColor.amber
        case .weak:
            return Color.red
        }
    }

    private var headerMetrics: [WorkflowMetric] {
        [
            WorkflowMetric(
                value: receipt.format.fileExtension.uppercased(),
                label: "Format",
                symbol: receipt.format.symbol,
                tint: PPColor.accent
            ),
            WorkflowMetric(
                value: "\(receipt.routeScore)",
                label: "Score",
                symbol: "gauge.with.dots.needle.67percent",
                tint: confidenceColor
            ),
            WorkflowMetric(
                value: receipt.routeConfidence.title,
                label: "Confidence",
                symbol: receipt.routeConfidence.symbol,
                tint: confidenceColor
            ),
            WorkflowMetric(
                value: receipt.isPinned ? "Pinned" : "7 days",
                label: "Retention",
                symbol: receipt.isPinned ? "pin.fill" : "clock",
                tint: receipt.isPinned ? PPColor.cyan : PPColor.mint
            )
        ]
    }

    private func evidenceGrid(
        _ evidence: PDFOfficeRuntimeEvidence
    ) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: PPSpacing.small),
            count: dynamicTypeSize.ppPrefersExpandedLayout ? 1 : 3
        )
        return LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: PPSpacing.small
        ) {
            evidenceMetric(
                "\(evidence.outputPageCount)/\(evidence.sourcePageCount)",
                label: "Pages",
                symbol: "doc.on.doc",
                tint: PPColor.accent
            )
            evidenceMetric(
                "\(evidence.pageYieldPercent)%",
                label: "Yield",
                symbol: "checkmark.seal",
                tint: evidence.pageYieldPercent == 100
                    ? PPColor.mint
                    : PPColor.amber
            )
            evidenceMetric(
                "\(evidence.searchableCoveragePercent)%",
                label: "Searchable",
                symbol: "text.magnifyingglass",
                tint: evidence.searchableCoveragePercent >= 80
                    ? PPColor.mint
                    : PPColor.amber
            )
            evidenceMetric(
                "\(evidence.primaryUnitCount)",
                label: evidence.primaryUnitLabel.capitalized,
                symbol: "square.grid.3x3",
                tint: PPColor.cyan
            )
            evidenceMetric(
                "\(evidence.characterCount)",
                label: "Characters",
                symbol: "textformat",
                tint: PPColor.accent
            )
            evidenceMetric(
                "\(evidence.searchablePageCount)",
                label: "Indexed pages",
                symbol: "doc.text.magnifyingglass",
                tint: PPColor.mint
            )
        }
    }

    private func resourceGrid(
        _ evidence: PDFOfficeRuntimeEvidence
    ) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: PPSpacing.small),
            count: dynamicTypeSize.ppPrefersExpandedLayout ? 1 : 3
        )
        return LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: PPSpacing.small
        ) {
            evidenceMetric(
                "\(evidence.assetCount)",
                label: "Assets",
                symbol: "photo.stack",
                tint: PPColor.cyan
            )
            evidenceMetric(
                evidence.formattedAssetBytes,
                label: "Asset bytes",
                symbol: "internaldrive",
                tint: PPColor.accent
            )
            evidenceMetric(
                "\(evidence.assetBudgetUsePercent)%",
                label: "Budget used",
                symbol: "gauge.with.dots.needle.50percent",
                tint: evidence.assetBudgetUsePercent > 85
                    ? PPColor.amber
                    : PPColor.mint
            )
            evidenceMetric(
                evidence.formattedAssetBudget,
                label: "Budget",
                symbol: "externaldrive.badge.checkmark",
                tint: PPColor.mint
            )
            evidenceMetric(
                "\(evidence.assetCompressionFallbackCount)",
                label: "Fallbacks",
                symbol: "arrow.down.right.and.arrow.up.left",
                tint: evidence.assetCompressionFallbackCount > 0
                    ? PPColor.amber
                    : PPColor.mint
            )
            evidenceMetric(
                evidence.assetMinimumQualityPercent > 0
                    ? "\(evidence.assetMinimumQualityPercent)%"
                    : "N/A",
                label: "Minimum quality",
                symbol: "slider.horizontal.3",
                tint: PPColor.cyan
            )
        }
    }

    private func runtimeSummary(
        _ evidence: PDFOfficeRuntimeEvidence
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.mint)
            Text(
                AppLocalization.format(
                    "%@ · %lld%% searchable · %lld%% visual budget",
                    evidence.yieldSummary,
                    evidence.searchableCoveragePercent,
                    evidence.assetBudgetUsePercent
                )
            )
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(PPColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func evidenceMetric(
        _ value: String,
        label: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.localizedUI)
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(label.localizedUI.uppercased())
                    .font(.caption2.smallCaps().weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.28))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func evidenceKeyValue(
        _ key: String,
        value: String
    ) -> some View {
        LabeledContent {
            Text(value.localizedUI)
                .font(.caption)
                .foregroundStyle(PPColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(key.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
    }

    private func preflightRow(
        _ signal: PDFOfficePreflightSignal
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Image(systemName: signal.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(readinessColor(signal.readiness))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(signal.title.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    Text(signal.value.localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(
                            readinessColor(signal.readiness)
                        )
                }
                Text(signal.detail.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func readinessColor(
        _ readiness: PDFOfficeExportReadiness
    ) -> Color {
        switch readiness {
        case .strong:
            return PPColor.mint
        case .review:
            return PPColor.amber
        case .limited:
            return Color.red
        }
    }
}

struct BatchSafeShareView: View {
    private enum Phase {
        case selecting
        case processing
        case finished
    }

    private enum ResultFilter: String, CaseIterable, Identifiable {
        case all
        case attention

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .attention: return "Needs attention"
            }
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @AppStorage("privacy.hideLibraryPreviews") private var hideLibraryPreviews = false

    var initialRecordIDs: Set<UUID>? = nil
    let onOpenDocument: (DocumentRoute) -> Void

    @State private var selectedIDs = Set<UUID>()
    @State private var items: [UUID: PDFBatchDeliveryItem] = [:]
    @State private var phase: Phase = .selecting
    @State private var batchTask: Task<Void, Never>?
    @State private var batchGeneration = UUID()
    @State private var isSharing = false
    @State private var preparedShareURLs: [URL] = []
    @State private var batchShareTask: Task<Void, Never>?
    @State private var batchShareGeneration = UUID()
    @State private var batchShareProgress: PDFOperationProgress?
    @State private var batchShareRateWindow = ByteRateWindow()
    @State private var batchShareFeedback = 0
    @State private var batchShareErrorFeedback = 0
    @State private var didInitialize = false
    @State private var wasStopped = false
    @State private var batchStopRequested = false
    @State private var dismissesAfterBatchStop = false
    @State private var batchRunID = UUID()
    @State private var batchStartedAt = Date()
    @State private var batchSourceRevisionIDs: [UUID: UUID] = [:]
    @State private var batchPersistenceTask: Task<Void, Never>?
    @State private var batchPersistenceGeneration = UUID()
    @State private var resultFilter: ResultFilter = .all
    @State private var selectedIssueItem: PDFBatchDeliveryItem?
    @State private var pendingIssueRoute: DocumentRoute?
    @State private var pendingIssueRetryRecordID: UUID?
    @State private var issueTransitionTask: Task<Void, Never>?
    @State private var issueTransitionGeneration = UUID()
    @State private var isConfirmingStopAndClose = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var confirmsUpdatedSources = false
    @State private var recheckRevisions: [UUID: UUID] = [:]
    @State private var omittedInitialCount = 0

    private let maximumBatchCount = 64

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.section
                    ) {
                        batchHeader
                        batchSearch

                        if let error = model.batchDeliveryPersistenceError {
                            VStack(alignment: .leading, spacing: PPSpacing.small) {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.subheadline)
                                    .foregroundStyle(PPColor.amber)
                                Button {
                                    Task { await persistBatchRun() }
                                } label: {
                                    Label("Retry Save".localizedUI, systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(PPQuietButtonStyle())
                                .disabled(phase == .processing)
                            }
                            .accessibilityIdentifier("batchPersistenceError")
                        }

                        if phase == .selecting {
                            selectionControls
                            if omittedInitialCount > 0 {
                                Label(
                                    AppLocalization.format(
                                        "%lld selected PDFs are unavailable or exceed the 64-file limit.",
                                        omittedInitialCount
                                    ),
                                    systemImage: "exclamationmark.circle"
                                )
                                .font(.caption)
                                .foregroundStyle(PPColor.amber)
                                .accessibilityIdentifier("batchOmittedSelection")
                            }
                        } else {
                            progressSummary
                            if phase == .finished,
                               verifiedCount > 0,
                               attentionCount + failedCount > 0 {
                                resultFilterControl
                            }
                        }

                        documentRows
                    }
                    .frame(maxWidth: 1_080)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 96)
                    .frame(maxWidth: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
            .navigationTitle("Verify Several PDFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            batchStopRequested
                                ? "Stopping"
                                : batchShareTask != nil
                                    ? "Stop"
                                    : phase == .processing
                                        ? "Stop"
                                        : phase == .finished
                                            ? "Done"
                                            : "Close"
                        ).localizedUI
                    ) {
                        if batchShareTask != nil {
                            stopBatchSharePreparation()
                        } else if phase == .processing {
                            isConfirmingStopAndClose = true
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(batchStopRequested)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                if phase == .finished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("New") {
                            resetBatch()
                        }
                        .disabled(batchShareTask != nil || model.activeBatchDeliveryRunID != nil)
                    }
                }
            }
        }
        .task {
            initializeSelectionIfNeeded()
        }
        .onChange(of: searchText) { _, value in
            if value.count > 256 { searchText = String(value.prefix(256)) }
        }
        .onChange(of: selectedRecords.map(\.contentRevisionID)) { _, _ in
            guard phase != .selecting else { return }
            for record in selectedRecords where
                batchSourceRevisionIDs[record.id] != record.contentRevisionID {
                items[record.id] = .changedSource(record.id)
            }
        }
        .confirmationDialog(
            "Recheck updated PDFs?",
            isPresented: $confirmsUpdatedSources,
            titleVisibility: .visible
        ) {
            Button("Check Current Versions".localizedUI) {
                let requested = selectedRecords.map(\.id).filter { recheckRevisions[$0] != nil }
                for id in requested { batchSourceRevisionIDs[id] = recheckRevisions[id] }
                recheckRevisions = [:]
                startBatch(recordIDs: requested)
            }
            Button("Cancel", role: .cancel) { recheckRevisions = [:] }
        } message: {
            Text("The updated files will be checked again. Previous outputs remain in Results.")
        }
        .onDisappear {
            cancelIssueTransition()
            if phase == .processing {
                stopBatchProcessing(invalidateResult: true)
            } else {
                persistLatestBatchSnapshot()
            }
            cancelBatchPersistence()
            stopBatchSharePreparation()
            isSharing = false
            cleanupPreparedBatchShares()
        }
        .sheet(
            isPresented: $isSharing,
            onDismiss: cleanupPreparedBatchShares
        ) {
            ShareSheet(
                items: preparedShareURLs.map { $0 as Any }
            )
        }
        .sheet(
            item: $selectedIssueItem,
            onDismiss: completeIssueTransition
        ) { item in
            BatchDeliveryIssueView(item: item) {
                pendingIssueRetryRecordID = item.sourceRecordID
                selectedIssueItem = nil
            } onOpenSource: {
                pendingIssueRoute = DocumentRoute(
                    recordID: item.sourceRecordID
                ).bindingExpectedRevision(
                    item.issue?.code == PDFBatchDeliveryIssue.sourceChanged.code
                        ? model.record(id: item.sourceRecordID)?.contentRevisionID
                        : batchSourceRevisionIDs[item.sourceRecordID]
                )
                selectedIssueItem = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Stop batch verification?",
            isPresented: $isConfirmingStopAndClose,
            titleVisibility: .visible
        ) {
            Button("Stop & Close", role: .destructive) {
                stopBatchProcessing(dismissAfterCompletion: true)
            }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text(
                "Verified outputs stay available. Unfinished PDFs can be resumed later."
            )
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            searchText = ""
            recheckRevisions = [:]
            confirmsUpdatedSources = false
            cancelIssueTransition()
            stopBatchSharePreparation()
            isSharing = false
            cleanupPreparedBatchShares()
            if self.phase == .processing {
                stopBatchProcessing()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            searchText = ""
            recheckRevisions = [:]
            confirmsUpdatedSources = false
            cancelIssueTransition()
            stopBatchSharePreparation()
            isSharing = false
            cleanupPreparedBatchShares()
            if phase == .processing {
                stopBatchProcessing()
            }
        }
        .interactiveDismissDisabled(
            phase == .processing || batchShareTask != nil
        )
        .sensoryFeedback(.success, trigger: verifiedCount)
        .sensoryFeedback(.success, trigger: batchShareFeedback)
        .sensoryFeedback(.error, trigger: batchShareErrorFeedback)
    }

    private var batchHeader: some View {
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: phase == .finished ? "checkmark.shield" : "doc.on.doc",
                tint: attentionCount + failedCount > 0 ? PPColor.amber : PPColor.accent,
                size: 44
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle.localizedUI)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headerDetail.localizedUI)
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var headerTitle: String {
        switch phase {
        case .selecting: return "Prepare several"
        case .processing:
            return batchStopRequested
                ? "Finishing current verification"
                : "Verifying one at a time"
        case .finished:
            if wasStopped {
                return "Batch stopped"
            }
            return attentionCount + failedCount > 0
                ? "Batch checked"
                : "Delivery copies ready"
        }
    }

    private var headerDetail: String {
        switch phase {
        case .selecting:
            return "Each PDF is checked separately. Originals stay unchanged."
        case .processing:
            return "Checks adapt to device load. Outputs stay one at a time."
        case .finished:
            return wasStopped
                ? AppLocalization.format(
                    "Verified copies still available: %lld",
                    verifiedCount
                )
                : AppLocalization.format(
                    "Verified: %lld · Need attention: %lld",
                    verifiedCount,
                    attentionCount + failedCount
                )
        }
    }

    private var selectionControls: some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(HStackLayout(spacing: PPSpacing.small))

        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    AppLocalization.format(
                        "%lld selected",
                        selectedIDs.count
                    )
                )
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textPrimary)
                Text(hiddenSelectedCount > 0
                    ? AppLocalization.format("%lld selected PDFs outside this search", hiddenSelectedCount)
                    : "Choose up to 64 source documents".localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
            Spacer(minLength: PPSpacing.small)
            Button(
                (allMatchesSelected ? "Deselect Matches" : "Select Matches").localizedUI
            ) {
                withAnimation(
                    reduceMotion
                        ? nil
                        : PPMotion.selection
                ) {
                    if allMatchesSelected {
                        selectedIDs.subtract(matchingRecords.map(\.id))
                    } else {
                        selectedIDs = PDFBatchSelection.adding(
                            matchingRecords.map(\.id), to: selectedIDs, limit: maximumBatchCount
                        )
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.accent)
            .frame(minHeight: 44)
            .disabled(matchingRecords.isEmpty || (!allMatchesSelected && selectedIDs.count >= maximumBatchCount))
            .accessibilityIdentifier("batchSelectMatches")
            .frame(
                maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                    ? .infinity
                    : nil,
                alignment: .leading
            )
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack {
                SectionEyebrow(
                    text: phase == .processing
                        ? "BATCH PROGRESS"
                        : "RESULTS"
                )
                Spacer()
                Text("\(completedCount)/\(selectedIDs.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textSecondary)
            }
            ProgressView(value: batchFraction)
                .tint(
                    phase == .finished
                        ? PPColor.mint
                        : PPColor.cyan
                )
            let metricsLayout = dynamicTypeSize.ppPrefersExpandedLayout
                ? AnyLayout(
                    VStackLayout(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    )
                )
                : AnyLayout(
                    HStackLayout(spacing: PPSpacing.large)
                )
            metricsLayout {
                resultMetric(
                    value: verifiedCount,
                    label: "Verified",
                    color: PPColor.mint
                )
                resultMetric(
                    value: attentionCount,
                    label: "Needs attention",
                    color: PPColor.amber
                )
                resultMetric(
                    value: failedCount,
                    label: "Unfinished",
                    color: unfinishedColor
                )
            }
        }
        .padding(.vertical, PPSpacing.small)
    }

    private var resultFilterControl: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                Menu {
                    ForEach(ResultFilter.allCases) { filter in
                        Button {
                            resultFilter = filter
                        } label: {
                            Label(
                                filter.title.localizedUI,
                                systemImage: resultFilter == filter
                                    ? "checkmark"
                                    : (
                                        filter == .all
                                            ? "tray.full"
                                            : "exclamationmark.triangle"
                                    )
                            )
                        }
                    }
                } label: {
                    HStack {
                        Label(
                            resultFilter.title.localizedUI,
                            systemImage: resultFilter == .all
                                ? "tray.full"
                                : "exclamationmark.triangle"
                        )
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, PPSpacing.small)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Picker("Batch results", selection: $resultFilter) {
                    ForEach(ResultFilter.allCases) { filter in
                        Text(filter.title.localizedUI)
                            .tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .accessibilityLabel("Filter batch results")
    }

    private func resultMetric(
        value: Int,
        label: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(
                    value == 0 ? PPColor.textSecondary : color
                )
                .contentTransition(.numericText())
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var documentRows: some View {
        if !normalizedQuery.isEmpty, displayedRecords.isEmpty {
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                Text("No matching PDFs".localizedUI).font(.headline)
                Button("Clear search".localizedUI) { searchText = "" }
                    .buttonStyle(PPQuietButtonStyle())
            }
        } else if phase == .selecting, eligibleRecords.isEmpty {
            PPEmptyState(
                kind: .workspace,
                title: "No eligible PDFs",
                message: "Import or unlock a PDF before starting batch verification."
            )
        } else if phase == .finished,
                  resultFilter == .attention,
                  displayedRecords.isEmpty {
            VStack(spacing: PPSpacing.medium) {
                PPEmptyState(
                    kind: .workspace,
                    title: "No PDFs need attention",
                    message: "Every finished item is ready in the full result list."
                )
                Button("Show All Results".localizedUI) {
                    resultFilter = .all
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.mint))
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(displayedRecords) { record in
                    batchDocumentRow(record)
                    Rectangle()
                        .fill(PPColor.border.opacity(0.52))
                        .frame(height: 0.6)
                        .padding(.leading, 76)
                }
            }
        }
    }

    private func batchDocumentRow(
        _ record: DocumentRecord
    ) -> some View {
        let item = items[record.id]
        let canOpenReview = item?.stage == .needsReview
            && item?.reviewPageIndex != nil
        let canOpenIssue = item?.issue != nil
        let output = item?.stage.isShareable == true
            && batchSourceRevisionIDs[record.id] == record.contentRevisionID
            ? item?.outputRecordID.flatMap { model.record(id: $0) }
            : nil

        return Button {
            if phase == .selecting {
                toggle(record.id)
            } else if let output {
                onOpenDocument(DocumentRoute(
                    recordID: output.id,
                    expectedContentRevisionID: output.contentRevisionID
                ))
            } else if canOpenReview,
                      let pageIndex = item?.reviewPageIndex {
                batchTask?.cancel()
                onOpenDocument(
                    DocumentRoute(
                        recordID: record.id,
                        pageIndex: pageIndex,
                        expectedContentRevisionID:
                            batchSourceRevisionIDs[record.id]
                    )
                )
            } else if canOpenIssue {
                selectedIssueItem = item
            }
        } label: {
            HStack(spacing: PPSpacing.medium) {
                ZStack(alignment: .bottomTrailing) {
                    if !hideLibraryPreviews,
                       let url = model.url(for: output?.id ?? record.id) {
                        PDFPageThumbnailView(
                            url: url,
                            pageIndex: 0,
                            refreshToken: model.refreshToken(
                                for: output?.id ?? record.id
                            ),
                            width: 50
                        )
                        .shadow(
                            color: .black.opacity(0.1),
                            radius: 4,
                            y: 2
                        )
                    } else {
                        ToolSymbolPlate(
                            symbol: hideLibraryPreviews ? "eye.slash" : record.profile.kind.symbol,
                            tint: PPColor.cyan,
                            size: 50
                        )
                    }
                    statusMark(item: item)
                        .offset(x: 6, y: 5)
                }
                .frame(width: 58, height: 70)

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(2)
                    Text((
                        phase == .selecting
                            ? record.subtitle
                            : (item?.detail ?? "Waiting")
                    ).localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)

                    if let issue = item?.issue {
                        Text(
                            "\(issue.phase.title.localizedUI.uppercased()) · \(issue.code)"
                        )
                        .font(.caption2.smallCaps().weight(.semibold))
                        .foregroundStyle(stageColor(item?.stage ?? .failed))
                        .lineLimit(1)

                        Text(issue.recovery.localizedUI)
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                            .lineLimit(2)
                    }

                    if item?.stage == .creating,
                       let progress = model.progress(for: record.id) {
                        ProgressView(
                            value: progress.fractionCompleted
                        )
                        .tint(PPColor.cyan)
                    }
                }

                Spacer(minLength: PPSpacing.small)

                if phase == .selecting {
                    Image(
                        systemName: selectedIDs.contains(record.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.title3)
                    .foregroundStyle(
                        selectedIDs.contains(record.id)
                            ? PPColor.accent
                            : PPColor.textSecondary
                    )
                } else if canOpenReview {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PPColor.amber)
                } else if canOpenIssue, let item {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(item.stage.title.localizedUI)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(stageColor(item.stage))
                        Image(systemName: "info.circle")
                            .font(.body)
                            .foregroundStyle(stageColor(item.stage))
                    }
                } else if let item {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(item.stage.title.localizedUI)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(stageColor(item.stage))
                        if output != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PPColor.mint)
                        }
                    }
                }
            }
            .frame(minHeight: 86)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(
            batchShareTask == nil
                && (
                    phase == .selecting
                        || canOpenReview
                        || canOpenIssue
                        || output != nil
                )
        )
        .accessibilityLabel(accessibilityLabel(record, item: item))
        .accessibilityIdentifier("batchDocument-\(record.id)")
    }

    @ViewBuilder
    private func statusMark(
        item: PDFBatchDeliveryItem?
    ) -> some View {
        if phase == .selecting {
            EmptyView()
        } else if let item {
            Image(systemName: item.stage.symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(stageColor(item.stage))
                .frame(width: 24, height: 24)
                .background(PPColor.surface, in: Circle())
                .overlay(Circle().stroke(stageColor(item.stage), lineWidth: 1))
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: !reduceMotion
                        && (
                            item.stage == .checking
                                || item.stage == .creating
                        )
                )
        } else {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
        }
    }

    private var actionFooter: some View {
        VStack(spacing: PPSpacing.small) {
            if let batchShareProgress {
                batchShareProgressRow(batchShareProgress)
            }

            if phase == .selecting {
                Button {
                    startBatch()
                } label: {
                    Label(
                        batchPrimaryTitle,
                        systemImage: "checkmark.shield"
                    )
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .disabled(selectedIDs.isEmpty || model.activeBatchDeliveryRunID != nil)
            } else if phase == .processing {
                Button {
                    stopBatchProcessing()
                } label: {
                    Label(
                        batchStopRequested
                            ? "Stopping safely"
                            : "Stop safely",
                        systemImage: batchStopRequested
                            ? "hourglass"
                            : "stop.fill"
                    )
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
                .disabled(batchStopRequested)
            } else {
                if !updatedSourceRecords.isEmpty {
                    Button {
                        recheckRevisions = Dictionary(uniqueKeysWithValues:
                            updatedSourceRecords.map { ($0.id, $0.contentRevisionID) }
                        )
                        confirmsUpdatedSources = true
                    } label: {
                        Label(
                            AppLocalization.format("Recheck %lld updated PDFs", updatedSourceRecords.count),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .disabled(batchShareTask != nil || model.activeBatchDeliveryRunID != nil)
                    .accessibilityIdentifier("batchRecheckUpdated")
                }
                if !retryableIDs.isEmpty {
                    Button {
                        startBatch(recordIDs: retryableIDs)
                    } label: {
                        Label(
                            AppLocalization.format(
                                "Retry %lld unfinished",
                                retryableIDs.count
                            ),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.amber)
                    )
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .disabled(batchShareTask != nil)
                }

                if verifiedCount > 0 {
                    Button {
                        prepareBatchShare()
                    } label: {
                        Label(
                            AppLocalization.format(
                                batchShareTask == nil
                                    ? "Share %lld Verified PDF%@"
                                    : "Verifying %lld PDF%@",
                                verifiedCount,
                                verifiedCount == 1 ? "" : "s"
                            ),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .disabled(batchShareTask != nil)
                } else if retryableIDs.isEmpty && updatedSourceRecords.isEmpty {
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(PPQuietButtonStyle())
                }
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.52))
                .frame(height: 0.6)
        }
    }

    private func batchShareProgressRow(
        _ progress: PDFOperationProgress
    ) -> some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .trailing,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(HStackLayout(spacing: PPSpacing.small))
        return layout {
            LocalOperationProgressView(progress: progress)
                .frame(maxWidth: .infinity)
            Button {
                stopBatchSharePreparation()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.amber)
            .accessibilityLabel("Stop preparing batch share")
            .accessibilityHint(
                "Deletes protected copies already prepared for this share"
            )
        }
    }

    private var eligibleRecords: [DocumentRecord] {
        model.workingDocuments
            .filter {
                !$0.profile.isLocked && model.url(for: $0.id) != nil
            }
            .sorted {
                $0.modifiedAt == $1.modifiedAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.modifiedAt > $1.modifiedAt
            }
    }

    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingRecords: [DocumentRecord] {
        eligibleRecords.filter { matchesSearch($0) }
    }

    private func matchesSearch(_ record: DocumentRecord) -> Bool {
        normalizedQuery.isEmpty
            || record.displayName.localizedStandardContains(normalizedQuery)
            || record.tags.contains { $0.localizedStandardContains(normalizedQuery) }
            || (phase != .selecting && (
                items[record.id]?.detail.localizedUI.localizedStandardContains(normalizedQuery) == true
                || items[record.id]?.stage.title.localizedUI.localizedStandardContains(normalizedQuery) == true
            ))
    }

    private var allMatchesSelected: Bool {
        !matchingRecords.isEmpty && matchingRecords.allSatisfy { selectedIDs.contains($0.id) }
    }

    private var hiddenSelectedCount: Int {
        selectedIDs.subtracting(matchingRecords.map(\.id)).count
    }

    private var updatedSourceRecords: [DocumentRecord] {
        selectedRecords.filter {
            items[$0.id]?.issue?.code == PDFBatchDeliveryIssue.sourceChanged.code
        }
    }

    private var batchSearch: some View {
        HStack(spacing: PPSpacing.small) {
            Button { isSearchFocused = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
            }
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel("Search batch PDFs".localizedUI)
            TextField("Search batch PDFs".localizedUI, text: $searchText)
                .focused($isSearchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("batchSearch")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear search".localizedUI)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(PPColor.textSecondary)
        .background(PPColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
        .disabled(phase == .processing || batchShareTask != nil)
    }

    private var selectedRecords: [DocumentRecord] {
        eligibleRecords.filter { selectedIDs.contains($0.id) }
    }

    private var displayedRecords: [DocumentRecord] {
        guard phase != .selecting else { return matchingRecords }
        let records = selectedRecords.filter { matchesSearch($0) }.sorted {
            let left = items[$0.id]?.stage.isShareable == true
            let right = items[$1.id]?.stage.isShareable == true
            return left != right ? !left : $0.modifiedAt > $1.modifiedAt
        }
        guard phase == .finished,
              resultFilter == .attention
        else { return records }
        return records.filter { record in
            guard let item = items[record.id] else { return false }
            return !item.stage.isShareable
        }
    }

    private var verifiedOutputRecords: [DocumentRecord] {
        selectedRecords.compactMap { record in
            guard let outputID = items[record.id]?.outputRecordID,
                  items[record.id]?.stage.isShareable == true,
                  batchSourceRevisionIDs[record.id] == record.contentRevisionID
            else { return nil }
            return model.record(id: outputID)
        }
    }

    private var completedCount: Int {
        selectedIDs.filter {
            items[$0]?.stage.isFinal == true
        }.count
    }

    private var verifiedCount: Int {
        selectedIDs.filter {
            items[$0]?.stage.isShareable == true
        }.count
    }

    private var attentionCount: Int {
        selectedIDs.filter {
            items[$0]?.stage == .needsReview
                || items[$0]?.stage == .blocked
        }.count
    }

    private var failedCount: Int {
        selectedIDs.filter {
            items[$0]?.stage == .failed
                || items[$0]?.stage == .stopped
        }.count
    }

    private var retryableIDs: [UUID] {
        let recordIDs: [UUID] = selectedRecords.compactMap { record in
            guard let item = items[record.id],
                  item.stage == .failed || item.stage == .stopped,
                  item.issue?.isRetryable != false
            else { return nil }
            return record.id
        }
        return Array(recordIDs.prefix(maximumBatchCount))
    }

    private var unfinishedColor: Color {
        selectedIDs.contains {
            items[$0]?.stage == .failed
        } ? .red : PPColor.amber
    }

    private var batchFraction: Double {
        guard !selectedIDs.isEmpty else { return 0 }
        let total = selectedIDs.reduce(0.0) { result, id in
            guard let item = items[id] else { return result }
            if item.stage.isFinal {
                return result + 1
            }
            if item.stage == .checking {
                return result + 0.12
            }
            if item.stage == .ready {
                return result + 0.2
            }
            if item.stage == .creating {
                return result + 0.2
                    + (model.progress(for: id)?
                        .fractionCompleted ?? 0) * 0.8
            }
            return result
        }
        return min(1, total / Double(selectedIDs.count))
    }

    private func initializeSelectionIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true
        if initialRecordIDs == nil, let run = model.currentBatchDeliveryRun() {
            selectedIDs = Set(run.sourceRecordIDs)
            batchSourceRevisionIDs = run.sourceRevisionIDs
            items = Dictionary(
                run.items.map {
                    ($0.sourceRecordID, $0)
                },
                uniquingKeysWith: { _, newest in newest }
            )
            batchRunID = run.id
            batchStartedAt = run.startedAt
            wasStopped = run.items.contains { $0.stage == .stopped }
            phase = .finished
            resultFilter = run.needsAttention ? .attention : .all
            return
        }
        let requested = initialRecordIDs ?? []
        selectedIDs = PDFBatchSelection.adding(
            eligibleRecords.filter { requested.contains($0.id) }.map(\.id),
            to: [], limit: maximumBatchCount
        )
        omittedInitialCount = requested.subtracting(selectedIDs).count
        batchSourceRevisionIDs = Dictionary(
            uniqueKeysWithValues: eligibleRecords.map {
                ($0.id, $0.contentRevisionID)
            }
        )
        items = Dictionary(
            eligibleRecords.map {
                (
                    $0.id,
                    PDFBatchDeliveryItem(
                        sourceRecordID: $0.id,
                        stage: .queued,
                        detail: "Waiting for local preflight"
                    )
                )
            },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    private func toggle(_ recordID: UUID) {
        withAnimation(
            reduceMotion
                ? nil
                : PPMotion.selection
        ) {
            if selectedIDs.contains(recordID) {
                selectedIDs.remove(recordID)
            } else {
                guard selectedIDs.count < maximumBatchCount else {
                    model[noticeFor: paperPathSceneID] =
                        "A batch can include up to 64 PDFs"
                            .localizedUI
                    return
                }
                selectedIDs.insert(recordID)
                if let revisionID = model.record(id: recordID)?
                    .contentRevisionID {
                    batchSourceRevisionIDs[recordID] = revisionID
                }
            }
        }
    }

    private func startBatch(
        recordIDs requestedIDs: [UUID]? = nil
    ) {
        guard batchTask == nil, !selectedIDs.isEmpty else { return }
        let requestedSourceIDs =
            requestedIDs ?? selectedRecords.map(\.id)
        guard !requestedSourceIDs.isEmpty else { return }
        if requestedIDs == nil {
            batchSourceRevisionIDs = Dictionary(
                uniqueKeysWithValues: selectedRecords.map {
                    ($0.id, $0.contentRevisionID)
                }
            )
        }
        let staleSourceIDs = requestedSourceIDs.filter {
            model.record(id: $0)?.contentRevisionID
                != batchSourceRevisionIDs[$0]
        }
        for sourceID in staleSourceIDs {
            items[sourceID] = .changedSource(sourceID)
        }
        let sourceIDs = requestedSourceIDs.filter {
            !staleSourceIDs.contains($0)
        }
        guard !sourceIDs.isEmpty else {
            phase = .finished
            model[noticeFor: paperPathSceneID] =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            persistLatestBatchSnapshot()
            return
        }
        if requestedIDs == nil {
            batchRunID = UUID()
            batchStartedAt = Date()
        }
        guard model.beginBatchDeliveryRun(id: batchRunID) else { return }
        phase = .processing
        searchText = ""
        isSearchFocused = false
        wasStopped = false
        batchStopRequested = false
        dismissesAfterBatchStop = false
        resultFilter = .all
        for sourceID in sourceIDs {
            items[sourceID] = PDFBatchDeliveryItem(
                sourceRecordID: sourceID,
                stage: .queued,
                detail: "Waiting for local preflight"
            )
        }
        let generation = UUID()
        let runID = batchRunID
        let expectedRevisions = batchSourceRevisionIDs
        batchGeneration = generation
        batchTask = Task {
            defer { model.endBatchDeliveryRun(id: runID) }
            guard await persistBatchRun() else {
                if batchGeneration == generation {
                    for id in sourceIDs {
                        let issue = PDFBatchDeliveryIssue.savingFailed(
                            "The batch recovery state could not be saved."
                        )
                        items[id] = PDFBatchDeliveryItem(
                            sourceRecordID: id, stage: .failed, detail: issue.message, issue: issue
                        )
                    }
                    batchTask = nil
                    phase = .finished
                }
                return
            }
            guard batchGeneration == generation else { return }
            let results = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createSafeShareBatch(
                    recordIDs: sourceIDs,
                    runID: runID,
                    expectedRevisionIDs: expectedRevisions
                ) { update in
                    guard batchGeneration == generation,
                          !Task.isCancelled
                    else { return }
                    withAnimation(
                        reduceMotion
                            ? nil
                            : PPMotion.selection
                    ) {
                        items[update.sourceRecordID] = update
                    }
                    scheduleBatchPersistence()
                }
            }
            guard batchGeneration == generation else { return }
            for result in results {
                items[result.sourceRecordID] = result
            }
            cancelBatchPersistence()
            await persistBatchRun()
            wasStopped =
                batchStopRequested || Task.isCancelled
            let shouldDismiss = dismissesAfterBatchStop
            batchStopRequested = false
            dismissesAfterBatchStop = false
            batchTask = nil
            phase = .finished
            if shouldDismiss {
                dismiss()
            }
        }
    }



    private var batchPrimaryTitle: String {
        return AppLocalization.format(
            "Check & Create %lld",
            selectedIDs.count
        )
    }

    private func resetBatch() {
        guard model.activeBatchDeliveryRunID == nil else { return }
        batchGeneration = UUID()
        batchTask?.cancel()
        batchTask = nil
        cancelBatchPersistence()
        cancelIssueTransition()
        selectedIssueItem = nil
        pendingIssueRoute = nil
        pendingIssueRetryRecordID = nil
        resultFilter = .all
        wasStopped = false
        batchStopRequested = false
        dismissesAfterBatchStop = false
        phase = .selecting
        searchText = ""
        omittedInitialCount = 0
        batchRunID = UUID()
        batchStartedAt = Date()
        selectedIDs = []
        batchSourceRevisionIDs = Dictionary(
            uniqueKeysWithValues: eligibleRecords.map {
                ($0.id, $0.contentRevisionID)
            }
        )
        items = Dictionary(
            eligibleRecords.map {
                (
                    $0.id,
                    PDFBatchDeliveryItem(
                        sourceRecordID: $0.id,
                        stage: .queued,
                        detail: "Waiting for local preflight"
                    )
                )
            },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    private func completeIssueTransition() {
        let route = pendingIssueRoute
        let recordID = pendingIssueRetryRecordID
        guard route != nil || recordID != nil else { return }
        pendingIssueRoute = nil
        pendingIssueRetryRecordID = nil
        issueTransitionTask?.cancel()
        let generation = UUID()
        issueTransitionGeneration = generation
        issueTransitionTask = Task { @MainActor in
            defer {
                if issueTransitionGeneration == generation {
                    issueTransitionTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  issueTransitionGeneration == generation,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            if let route {
                guard model.record(id: route.recordID) != nil else {
                    return
                }
                batchTask?.cancel()
                onOpenDocument(route)
            } else if let recordID {
                startBatch(recordIDs: [recordID])
            }
        }
    }

    private func cancelIssueTransition() {
        issueTransitionGeneration = UUID()
        issueTransitionTask?.cancel()
        issueTransitionTask = nil
        pendingIssueRoute = nil
        pendingIssueRetryRecordID = nil
    }

    private func stopBatchProcessing(
        dismissAfterCompletion: Bool = false,
        invalidateResult: Bool = false
    ) {
        guard phase == .processing,
              !batchStopRequested || invalidateResult
        else { return }
        wasStopped = true
        dismissesAfterBatchStop =
            dismissesAfterBatchStop || dismissAfterCompletion
        if !invalidateResult {
            batchStopRequested = true
            batchTask?.cancel()
            return
        }
        batchGeneration = UUID()
        batchTask?.cancel()
        batchTask = nil
        batchStopRequested = false
        dismissesAfterBatchStop = false
        for recordID in selectedIDs {
            guard let item = items[recordID],
                  !item.stage.isFinal
            else { continue }
            items[recordID] = PDFBatchDeliveryItem(
                sourceRecordID: recordID,
                outputRecordID: item.outputRecordID,
                stage: .stopped,
                detail: "Stopped safely",
                issue: .cancelled
            )
        }
        phase = .finished
        persistLatestBatchSnapshot()
    }

    private func scheduleBatchPersistence() {
        batchPersistenceTask?.cancel()
        let generation = UUID()
        batchPersistenceGeneration = generation
        let runID = batchRunID
        let startedAt = batchStartedAt
        let sourceIDs = selectedRecords.map(\.id)
        let sourceRevisionIDs = batchSourceRevisionIDs
        let snapshot = sourceIDs.compactMap { items[$0] }
        let snapshotAt = Date()
        batchPersistenceTask = Task {
            defer {
                if batchPersistenceGeneration == generation {
                    batchPersistenceTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(240))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  batchPersistenceGeneration == generation
            else { return }
            await model.saveBatchDeliveryRun(
                id: runID,
                sourceRecordIDs: sourceIDs,
                sourceRevisionIDs: sourceRevisionIDs,
                items: snapshot,
                startedAt: startedAt,
                snapshotAt: snapshotAt
            )
        }
    }

    private func cancelBatchPersistence() {
        batchPersistenceGeneration = UUID()
        batchPersistenceTask?.cancel()
        batchPersistenceTask = nil
    }

    @discardableResult
    private func persistBatchRun() async -> Bool {
        let sourceIDs = selectedRecords.map(\.id)
        let runID = batchRunID
        let revisions = batchSourceRevisionIDs
        let snapshot = sourceIDs.compactMap { items[$0] }
        let startedAt = batchStartedAt
        let snapshotAt = Date()
        // The final recovery snapshot must survive cancellation of the batch worker.
        return await Task { @MainActor in
            await model.saveBatchDeliveryRun(
                id: runID, sourceRecordIDs: sourceIDs,
                sourceRevisionIDs: revisions, items: snapshot,
                startedAt: startedAt, snapshotAt: snapshotAt
            )
        }.value
    }

    private func persistLatestBatchSnapshot() {
        guard phase != .selecting else { return }
        let runID = batchRunID
        let startedAt = batchStartedAt
        let sourceIDs = selectedRecords.map(\.id)
        let sourceRevisionIDs = batchSourceRevisionIDs
        let snapshot = sourceIDs.compactMap { items[$0] }
        let snapshotAt = Date()
        Task {
            await model.saveBatchDeliveryRun(
                id: runID,
                sourceRecordIDs: sourceIDs,
                sourceRevisionIDs: sourceRevisionIDs,
                items: snapshot,
                startedAt: startedAt,
                snapshotAt: snapshotAt
            )
        }
    }

    private func prepareBatchShare() {
        guard batchShareTask == nil,
              !isSharing
        else { return }
        let records = verifiedOutputRecords
        guard !records.isEmpty,
              records.count == verifiedCount
        else {
            model[noticeFor: paperPathSceneID] =
                "One or more verified PDFs are no longer available."
                    .localizedUI
            batchShareErrorFeedback += 1
            return
        }

        cleanupPreparedBatchShares()
        let generation = UUID()
        batchShareGeneration = generation
        batchShareRateWindow.reset()
        batchShareProgress = PDFOperationProgress(
            label: AppLocalization.format(
                "Verifying %lld PDF%@",
                records.count,
                records.count == 1 ? "" : "s"
            ),
            fractionCompleted: 0,
            byteStage: .verifying
        )
        batchShareTask = Task { @MainActor in
            var preparedURLs: [URL] = []
            let workByRecord = records.map {
                let (doubled, overflow) = max(
                    1,
                    $0.profile.byteCount
                ).multipliedReportingOverflow(by: 2)
                return overflow ? Int64.max : max(2, doubled)
            }
            let totalBytes = max(
                1,
                workByRecord.reduce(Int64.zero) { total, bytes in
                    let (next, overflow) =
                        total.addingReportingOverflow(bytes)
                    return overflow ? .max : next
                }
            )
            var completedBytes: Int64 = 0

            for (index, record) in records.enumerated() {
                guard !Task.isCancelled,
                      batchShareGeneration == generation
                else {
                    await discardBatchShareCopies(preparedURLs)
                    return
                }
                let unitBytes = workByRecord[index]
                let completedBeforeCurrent = completedBytes
                let preparedURL = await model.withFeedbackTarget(
                    paperPathSceneID
                ) {
                    await model.makeFilesExportCopy(
                        recordID: record.id
                    ) { update in
                        guard batchShareGeneration == generation else {
                            return
                        }
                        let updateBytes = min(
                            unitBytes,
                            max(0, update.processedBytes)
                        )
                        let cumulativeUpdate = PDFByteProgressUpdate(
                            stage: .verifying,
                            processedBytes: {
                                let (next, overflow) =
                                    completedBeforeCurrent
                                        .addingReportingOverflow(
                                            updateBytes
                                        )
                                return overflow
                                    ? totalBytes
                                    : min(totalBytes, next)
                            }(),
                            totalBytes: totalBytes,
                            completedUnitCount: index,
                            totalUnitCount: records.count,
                            currentUnitName: record.displayName
                        )
                        if let progress = batchShareRateWindow
                            .operationProgress(
                                label: AppLocalization.format(
                                    "Verifying PDF %lld of %lld",
                                    index + 1,
                                    records.count
                                ),
                                update: cumulativeUpdate,
                                current: batchShareProgress
                            ) {
                            batchShareProgress = progress
                        }
                    }
                }
                guard let preparedURL else {
                    await discardBatchShareCopies(preparedURLs)
                    guard batchShareGeneration == generation,
                          !Task.isCancelled
                    else { return }
                    batchShareTask = nil
                    batchShareProgress = nil
                    batchShareRateWindow.reset()
                    batchShareErrorFeedback += 1
                    return
                }
                preparedURLs.append(preparedURL)
                let (nextCompletedBytes, overflow) = completedBytes
                    .addingReportingOverflow(unitBytes)
                completedBytes = overflow
                    ? totalBytes
                    : min(totalBytes, nextCompletedBytes)
            }

            guard !Task.isCancelled,
                  batchShareGeneration == generation
            else {
                await discardBatchShareCopies(preparedURLs)
                return
            }
            batchShareTask = nil
            batchShareProgress = nil
            batchShareRateWindow.reset()
            preparedShareURLs = preparedURLs
            batchShareFeedback += 1
            isSharing = true
        }
    }

    private func stopBatchSharePreparation() {
        batchShareGeneration = UUID()
        batchShareTask?.cancel()
        batchShareTask = nil
        batchShareProgress = nil
        batchShareRateWindow.reset()
    }

    private func cleanupPreparedBatchShares() {
        let urls = preparedShareURLs
        preparedShareURLs = []
        guard !urls.isEmpty else { return }
        Task {
            await discardBatchShareCopies(urls)
        }
    }

    private func discardBatchShareCopies(
        _ urls: [URL]
    ) async {
        for url in urls {
            await model.discardFilesExportCopy(at: url)
        }
    }

    private func stageColor(
        _ stage: PDFBatchDeliveryStage
    ) -> Color {
        switch stage {
        case .queued: return PPColor.textSecondary
        case .checking, .ready, .creating: return PPColor.cyan
        case .verified, .reused: return PPColor.mint
        case .needsReview: return PPColor.amber
        case .blocked, .failed: return .red
        case .stopped: return PPColor.amber
        }
    }

    private func accessibilityLabel(
        _ record: DocumentRecord,
        item: PDFBatchDeliveryItem?
    ) -> String {
        if phase == .selecting {
            return AppLocalization.format(
                "%@, %@",
                record.displayName,
                (
                    selectedIDs.contains(record.id)
                        ? "Selected"
                        : "Not selected"
                ).localizedUI
            )
        }
        return [
            record.displayName,
            (item?.stage.title ?? "Waiting").localizedUI,
            (item?.detail ?? "").localizedUI,
            (item?.issue?.recovery ?? "").localizedUI
        ]
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

private struct BatchDeliveryIssueView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("privacy.hideLibraryPreviews") private var hideLibraryPreviews = false

    let item: PDFBatchDeliveryItem
    let onRetry: () -> Void
    let onOpenSource: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.section
                    ) {
                        issueHeader
                        stageTimeline
                        issueExplanation
                    }
                    .frame(maxWidth: 620)
                    .padding(PPSpacing.xLarge)
                    .padding(.bottom, 92)
                    .frame(maxWidth: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
            .navigationTitle("Delivery issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private var issueHeader: some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.medium
                )
            )
            : AnyLayout(
                HStackLayout(
                    alignment: .top,
                    spacing: PPSpacing.large
                )
            )

        return layout {
            if !hideLibraryPreviews,
               let record, !record.profile.isLocked,
               let url = model.url(for: record.id) {
                PDFPageThumbnailView(
                    url: url,
                    pageIndex: 0,
                    refreshToken: model.refreshToken(for: record.id),
                    width: 72
                )
                .shadow(
                    color: .black.opacity(0.12),
                    radius: 6,
                    y: 3
                )
            } else {
                TaskPathArtwork(
                    package: .prepareToSend,
                    tint: issueColor,
                    compact: true
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                SectionEyebrow(
                    text: "\(issue.phase.title.localizedUI.uppercased()) · \(issue.code)"
                )
                Text(record?.displayName ?? "Source PDF")
                    .font(.title2.bold())
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(issue.message.localizedUI)
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stageTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(text: "DELIVERY PATH")
                .padding(.bottom, PPSpacing.medium)

            ForEach(
                Array(timelineStages.enumerated()),
                id: \.element.title
            ) { index, stage in
                HStack(alignment: .top, spacing: PPSpacing.medium) {
                    VStack(spacing: 0) {
                        Image(systemName: stage.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(stage.color)
                            .frame(width: 28, height: 28)
                        if index < timelineStages.count - 1 {
                            Rectangle()
                                .fill(PPColor.border)
                                .frame(width: 1, height: 28)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.title.localizedUI)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Text(stage.detail.localizedUI)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    .padding(.bottom, PPSpacing.medium)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var issueExplanation: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "NEXT STEP")
            Text(issue.recovery.localizedUI)
                .font(.body)
                .foregroundStyle(PPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Verified files from the same batch remain available and are not recreated."
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, PPSpacing.medium)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var actionFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.medium) {
                openSourceButton
                if issue.isRetryable {
                    retryButton
                }
            }
            VStack(spacing: PPSpacing.small) {
                if issue.isRetryable {
                    retryButton
                }
                openSourceButton
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.52))
                .frame(height: 0.6)
        }
    }

    private var openSourceButton: some View {
        Button {
            onOpenSource()
        } label: {
            Label("Open Source", systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(PPQuietButtonStyle())
    }

    private var retryButton: some View {
        Button {
            onRetry()
        } label: {
            Label("Retry This PDF", systemImage: "arrow.clockwise")
        }
        .buttonStyle(PPPrimaryButtonStyle())
    }

    private var record: DocumentRecord? {
        model.record(id: item.sourceRecordID)
    }

    private var issue: PDFBatchDeliveryIssue {
        item.issue ?? .preflightFailed(item.detail)
    }

    private var issueColor: Color {
        issue.phase == .cancelled ? PPColor.amber : .red
    }

    private var timelineStages: [IssueTimelineStage] {
        if issue.phase == .cancelled {
            return [
                IssueTimelineStage(
                    title: "Queued",
                    detail: "This PDF remains in the local delivery queue",
                    symbol: "checkmark.circle.fill",
                    color: PPColor.mint
                ),
                IssueTimelineStage(
                    title: "Stopped",
                    detail: issue.message,
                    symbol: "pause.circle.fill",
                    color: PPColor.amber
                ),
                IssueTimelineStage(
                    title: "Verify & save",
                    detail: "Not completed",
                    symbol: "circle",
                    color: PPColor.textSecondary
                )
            ]
        }

        let phases: [
            (PDFBatchDeliveryFailurePhase, String, String)
        ] = [
            (.source, "Source", "Private working copy available"),
            (.preflight, "Preflight", "Pages and editable layers checked"),
            (.rendering, "Create", "Verified copy pages rendered"),
            (.verification, "Verify", "Output reopened and audited"),
            (.saving, "Save", "Verified copy added to the library")
        ]
        let failureIndex = phases.firstIndex {
            $0.0 == issue.phase
        } ?? 0
        return phases.enumerated().map { index, value in
            if index < failureIndex {
                return IssueTimelineStage(
                    title: value.1,
                    detail: value.2,
                    symbol: "checkmark.circle.fill",
                    color: PPColor.mint
                )
            }
            if index == failureIndex {
                return IssueTimelineStage(
                    title: value.1,
                    detail: issue.message,
                    symbol: "xmark.circle.fill",
                    color: .red
                )
            }
            return IssueTimelineStage(
                title: value.1,
                detail: "Not reached",
                symbol: "circle",
                color: PPColor.textSecondary
            )
        }
    }

    private struct IssueTimelineStage {
        let title: String
        let detail: String
        let symbol: String
        let color: Color
    }
}

struct SourceLocationView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let onOpenDocument: (DocumentRoute) -> Void

    @State private var snapshot: PDFSourceLocationSnapshot?
    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var exportTask: Task<Void, Never>?
    @State private var isWorking = false
    @State private var actionTask: Task<Void, Never>?
    @State private var sourceGeneration = 0
    @State private var operationGeneration = UUID()
    @State private var actionStopRequested = false
    @State private var exportProgress: PDFOperationProgress?
    @State private var exportRateWindow = ByteRateWindow()
    @AppStorage(AppPreferences.metadataSyncEnabledKey)
    private var metadataSyncEnabled = false

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                sourceContent
            }
            .overlay(alignment: .topTrailing) {
                if isLoading, snapshot != nil {
                    ProgressView()
                        .controlSize(.small)
                        .padding(PPSpacing.regular)
                }
            }
            .navigationTitle("Files & Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        (
                            actionStopRequested
                                ? "Stopping"
                                : isWorking
                                    ? "Stop"
                                    : "Close"
                        ).localizedUI
                    ) {
                        if isWorking {
                            stopCurrentOperation()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(actionStopRequested)
                }
            }
            .task {
                await reload()
            }
            .sheet(
                isPresented: $isExporting,
                onDismiss: discardPreparedExport
            ) {
                if let exportURL {
                    FileExportPicker(
                        url: exportURL,
                        onCompletion: {
                            isExporting = false
                        }
                    )
                        .ignoresSafeArea()
                }
            }
            .onDisappear {
                guard !isExporting else { return }
                interruptProtectedSourceWork()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await reload() }
                } else if phase == .background {
                    interruptProtectedSourceWork()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptProtectedSourceWork()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataDidBecomeAvailableNotification
                )
            ) { _ in
                guard scenePhase == .active else { return }
                Task { await reload() }
            }
            .interactiveDismissDisabled(isWorking)
            .accessibilityAction(.escape) {
                if isWorking {
                    stopCurrentOperation()
                } else {
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var sourceContent: some View {
        if isLoading, snapshot == nil {
            PPEmptyState(
                kind: .processing,
                title: "Checking Files source",
                message: "Reading source provenance from the private working copy."
            )
            .frame(maxWidth: 520)
            .padding(PPSpacing.regular)
        } else if let loadErrorMessage {
            VStack(spacing: PPSpacing.medium) {
                PPEmptyState(
                    kind: .tools,
                    title: "Couldn’t inspect source",
                    message: loadErrorMessage
                )
                Button {
                    Task {
                        await reload()
                    }
                } label: {
                    Label(
                        "Inspect Again",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
                .disabled(isLoading)
                .accessibilityIdentifier("retrySourceInspection")
            }
            .frame(maxWidth: 520)
            .padding(PPSpacing.regular)
        } else {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.large
                ) {
                    sourceHeader
                    sourceProvenance
                    metadataSection
                    sourceActions
                }
                .frame(maxWidth: 760)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var sourceHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "SOURCE WORKFLOW",
            title: snapshot?.status.title ?? "Checking source",
            detail: snapshot?.name
                ?? "This working copy is managed privately by PaperPath.",
            symbol: snapshot?.status.symbol
                ?? "folder.badge.questionmark",
            tint: statusColor,
            metrics: [
                WorkflowMetric(
                    value: snapshot?.isUbiquitous == true
                        ? "iCloud Drive"
                        : snapshot?.resolvedURL == nil
                            ? "Local only"
                            : "Files",
                    label: "Provider",
                    symbol: snapshot?.isUbiquitous == true
                        ? "icloud"
                        : "folder",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: model.record(id: recordID).map {
                        String(
                            $0.contentRevisionID.uuidString.prefix(8)
                        )
                    } ?? "—",
                    label: "Revision",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: metadataSyncEnabled ? "On" : "Off",
                    label: "Metadata",
                    symbol: metadataSyncEnabled
                        ? "checkmark.icloud"
                        : "icloud.slash",
                    tint: metadataSyncEnabled
                        ? PPColor.mint
                        : PPColor.textSecondary
                )
            ]
        )
    }

    private var sourceProvenance: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            WorkflowSectionHeader(
                eyebrow: "PRIVATE WORKING COPY",
                title: "Files provenance"
            )
            sourceStatus
            Label(
                "Originals in Files stay unchanged. Export or import a new copy.",
                systemImage: "lock.doc"
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
        }
    }

    private var metadataSection: some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(
                HStackLayout(
                    alignment: .top,
                    spacing: PPSpacing.medium
                )
            )

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            WorkflowSectionHeader(
                eyebrow: "OPTIONAL METADATA",
                title: metadataSyncEnabled
                    ? metadataSyncTitle
                    : "iCloud metadata is off"
            )
            layout {
                HStack(alignment: .top, spacing: PPSpacing.medium) {
                    Image(systemName: metadataSyncSymbol)
                        .foregroundStyle(metadataSyncColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.metadataSyncStatus.detail.localizedUI)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                        if let updatedAt =
                            model.metadataSyncStatus.updatedAt {
                            Text(
                                updatedAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(PPColor.textSecondary)
                        }
                    }
                }
                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer()
                }
                if metadataSyncEnabled {
                    Button {
                        Task {
                            await model.withFeedbackTarget(
                                paperPathSceneID
                            ) {
                                await model.synchronizeMetadata()
                            }
                        }
                    } label: {
                        Image(
                            systemName:
                                "arrow.triangle.2.circlepath"
                        )
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        model.metadataSyncStatus.state == .syncing
                    )
                    .accessibilityLabel("Sync Metadata Now")
                }
            }
            .padding(.vertical, PPSpacing.small)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.58))
                    .frame(height: 0.6)
            }
        }
    }

    private var sourceActions: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            WorkflowSectionHeader(
                eyebrow: "NEXT ACTION",
                title: sourceActionTitle
            )

            Button {
                prepareExport()
            } label: {
                Label(
                    "Save Working Copy to Files",
                    systemImage: "folder.badge.plus"
                )
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(workingURL == nil || isWorking)

            if let exportProgress {
                LocalOperationProgressView(progress: exportProgress)
                    .transition(.opacity)
            }

            if snapshot?.status == .changed
                || snapshot?.status == .stale {
                Button {
                    importChangedSource()
                } label: {
                    Label(
                        "Import Changed Source as New Copy",
                        systemImage:
                            "arrow.triangle.2.circlepath.doc.on.clipboard"
                    )
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
                .disabled(isWorking)
            }
        }
    }

    private var sourceActionTitle: String {
        switch snapshot?.status {
        case .changed, .stale:
            return "Preserve both versions"
        case .current:
            return "Export safely"
        case .unavailable:
            return "Save a new Files copy"
        case .detached, nil:
            return "Choose a Files destination"
        }
    }

    private var sourceStatus: some View {
        HStack(spacing: PPSpacing.medium) {
            Image(
                systemName: snapshot?.status.symbol
                    ?? "icloud.and.arrow.down"
            )
            .foregroundStyle(statusColor)
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    snapshot?.status.title
                        ?? "Checking source"
                )
                .font(.headline)
                if let name = snapshot?.name {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(2)
                }
                if snapshot?.isUbiquitous == true {
                    Text("iCloud Drive")
                        .font(.caption2.smallCaps().weight(.semibold))
                        .foregroundStyle(PPColor.cyan)
                }
            }
            Spacer()
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("sourceLocationStatus")
    }

    private var statusColor: Color {
        switch snapshot?.status {
        case .current: return PPColor.mint
        case .changed, .stale: return PPColor.amber
        case .unavailable: return .red
        case .detached, nil: return PPColor.textSecondary
        }
    }

    private var metadataSyncTitle: String {
        switch model.metadataSyncStatus.state {
        case .idle: return "Ready to sync"
        case .syncing: return "Syncing metadata"
        case .synced:
            let count = model.metadataSyncStatus.documentCount
            return "\(count) document\(count == 1 ? "" : "s") current"
        case .unavailable: return "iCloud unavailable"
        case .failed: return "Sync needs attention"
        }
    }

    private var metadataSyncSymbol: String {
        guard metadataSyncEnabled else { return "icloud.slash" }
        switch model.metadataSyncStatus.state {
        case .idle: return "icloud"
        case .syncing: return "icloud.and.arrow.up"
        case .synced: return "checkmark.icloud"
        case .unavailable: return "icloud.slash"
        case .failed: return "exclamationmark.icloud"
        }
    }

    private var metadataSyncColor: Color {
        guard metadataSyncEnabled else {
            return PPColor.textSecondary
        }
        switch model.metadataSyncStatus.state {
        case .synced: return PPColor.mint
        case .failed: return .red
        case .unavailable: return PPColor.amber
        case .idle, .syncing: return PPColor.cyan
        }
    }

    private var workingURL: URL? {
        model.url(for: recordID)
    }

    private func reload() async {
        sourceGeneration += 1
        let generation = sourceGeneration
        isLoading = true
        loadErrorMessage = nil
        defer {
            if generation == sourceGeneration {
                isLoading = false
            }
        }
        let loadedSnapshot = await model.sourceLocation(
            recordID: recordID
        )
        guard !Task.isCancelled,
              generation == sourceGeneration
        else { return }
        guard let loadedSnapshot else {
            snapshot = nil
            loadErrorMessage =
                "The private working copy or its source metadata could not be opened."
                    .localizedUI
            return
        }
        snapshot = loadedSnapshot
    }

    private func prepareExport() {
        guard actionTask == nil,
              exportTask == nil,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        let generation = UUID()
        operationGeneration = generation
        actionStopRequested = false
        isWorking = true
        exportRateWindow.reset()
        exportProgress = PDFOperationProgress(
            label: "Verifying protected copy",
            fractionCompleted: 0,
            byteStage: .checksumming
        )
        exportTask = Task { @MainActor in
            let preparedURL = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.makeFilesExportCopy(
                    recordID: recordID
                ) { update in
                    guard operationGeneration == generation else {
                        return
                    }
                    if let progress =
                        exportRateWindow.operationProgress(
                            label: "Verifying protected copy",
                            update: update,
                            current: exportProgress
                        ) {
                        exportProgress = progress
                    }
                }
            }
            guard operationGeneration == generation else {
                if let preparedURL {
                    await model.discardFilesExportCopy(at: preparedURL)
                }
                return
            }
            exportTask = nil
            isWorking = false
            exportProgress = nil
            exportRateWindow.reset()
            guard !Task.isCancelled else {
                if let preparedURL {
                    await model.discardFilesExportCopy(at: preparedURL)
                }
                return
            }
            exportURL = preparedURL
            isExporting = preparedURL != nil
        }
    }

    private func discardPreparedExport() {
        guard let preparedURL = exportURL else { return }
        exportURL = nil
        Task {
            await model.discardFilesExportCopy(at: preparedURL)
        }
    }

    private func stopCurrentOperation(
        invalidateResult: Bool = false
    ) {
        if !invalidateResult,
           actionTask != nil {
            guard !actionStopRequested else { return }
            actionStopRequested = true
            actionTask?.cancel()
            return
        }
        operationGeneration = UUID()
        exportTask?.cancel()
        actionTask?.cancel()
        exportTask = nil
        actionTask = nil
        isWorking = false
        actionStopRequested = false
        exportProgress = nil
        exportRateWindow.reset()
    }

    private func interruptProtectedSourceWork() {
        sourceGeneration += 1
        isLoading = false
        stopCurrentOperation(invalidateResult: true)
        isExporting = false
        discardPreparedExport()
    }

    private func importChangedSource() {
        guard actionTask == nil,
              exportTask == nil,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        let generation = UUID()
        operationGeneration = generation
        actionStopRequested = false
        isWorking = true
        actionTask = Task { @MainActor in
            let imported = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.importLatestSource(
                    recordID: recordID
                )
            }
            guard operationGeneration == generation else { return }
            let wasStopped =
                actionStopRequested || Task.isCancelled
            actionTask = nil
            isWorking = false
            actionStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    imported == nil
                        ? "Source import stopped"
                        : "Document saved before stopping"
                ).localizedUI
                return
            }
            guard let imported else { return }
            onOpenDocument(
                DocumentRoute(recordID: imported.id)
            )
        }
    }
}
