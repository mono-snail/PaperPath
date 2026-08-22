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

struct BatchCompressionView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("privacy.hideLibraryPreviews")
    private var hideLibraryPreviews = false

    let onOpen: (DocumentRoute) -> Void

    @State private var selectedIDs: [UUID] = []
    @State private var quality = PDFCompressionQuality.balanced
    @State private var isAddingFiles = false
    @State private var operationTask: Task<Void, Never>?
    @State private var currentRecordID: UUID?
    @State private var completedCount = 0
    @State private var results: [CompressionTaskResult] = []
    @State private var hasCompletedBatch = false

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
                            operationTask == nil
                                ? (hasCompletedBatch ? "Done" : "Cancel")
                                : "Stop"
                        ).localizedUI
                    ) {
                        if let operationTask {
                            operationTask.cancel()
                        } else {
                            dismiss()
                        }
                    }
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
            guard case .success(let urls) = result, !urls.isEmpty else {
                if case .failure(let error) = result {
                    model.present(error)
                }
                return
            }
            Task {
                let imported = await model.importPDFs(from: urls)
                for record in imported
                where PDFQuickTask.compressPDF.supports(record)
                    && !selectedIDs.contains(record.id) {
                    selectedIDs.append(record.id)
                }
            }
        }
        .onDisappear {
            operationTask?.cancel()
        }
        .sensoryFeedback(.selection, trigger: selectedIDs.count)
        .sensoryFeedback(.success, trigger: hasCompletedBatch)
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: PPSpacing.large) {
            taskHeader
            if horizontalSizeClass == .regular,
               !dynamicTypeSize.isAccessibilitySize {
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
        WorkflowCommandHeader(
            eyebrow: "BATCH COMPRESSION",
            title: "Compress PDF",
            detail: "Create separate smaller copies while sources stay unchanged.",
            symbol: "arrow.down.right.and.arrow.up.left",
            tint: PPColor.accent,
            metrics: [
                WorkflowMetric(
                    value: "\(selectedIDs.count)",
                    label: "Selected",
                    symbol: "checkmark.circle",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: formattedSelectedSize,
                    label: "Input",
                    symbol: "internaldrive",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: quality.title,
                    label: "Quality",
                    symbol: "slider.horizontal.3",
                    tint: PPColor.mint
                )
            ]
        )
    }

    private var qualityControl: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "OUTPUT QUALITY")
            Picker("Output quality", selection: $quality) {
                ForEach(PDFCompressionQuality.allCases) { option in
                    Text(option.title.localizedUI)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(quality.detail.localizedUI)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
        .disabled(operationTask != nil || model.isImporting)
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
                            dynamicTypeSize.isAccessibilitySize ? 2 : 1
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
            "\(record.displayName), \(selected ? "selected" : "not selected")"
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
            title: AppLocalization.format(
                "%lld of %lld ready",
                successfulCount,
                results.count
            ),
            detail: "Each result is a separate private PDF.",
            symbol: successfulCount == results.count
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill",
            tint: successfulCount == results.count
                ? PPColor.mint
                : PPColor.amber,
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
        Button {
            guard let outputID = result.outputID else { return }
            dismiss()
            onOpen(DocumentRoute(recordID: outputID))
        } label: {
            HStack(spacing: PPSpacing.medium) {
                Image(
                    systemName: result.outputID == nil
                        ? "xmark.circle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.title3)
                .foregroundStyle(
                    result.outputID == nil ? Color.red : PPColor.mint
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
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: PPSpacing.small) {
            if let operationTask {
                HStack {
                    Text(
                        AppLocalization.format(
                            "Compressing %lld of %lld",
                            min(completedCount + 1, selectedIDs.count),
                            selectedIDs.count
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
                    operationTask.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
            } else if hasCompletedBatch {
                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(PPPrimaryButtonStyle())
            } else {
                Button {
                    operationTask = Task {
                        await runCompression()
                    }
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
                .disabled(selectedIDs.isEmpty || model.isImporting)
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

    private var formattedSelectedSize: String {
        ByteCountFormatter.string(
            fromByteCount: selectedRecords.reduce(0) {
                $0 + $1.profile.byteCount
            },
            countStyle: .file
        )
    }

    private var successfulCount: Int {
        results.filter { $0.outputID != nil }.count
    }

    private var resultInputBytes: Int64 {
        results.reduce(0) { $0 + $1.sourceByteCount }
    }

    private var resultOutputBytes: Int64 {
        results.reduce(0) {
            $0 + ($1.outputByteCount ?? 0)
        }
    }

    private var formattedResultInputSize: String {
        ByteCountFormatter.string(
            fromByteCount: resultInputBytes,
            countStyle: .file
        )
    }

    private var formattedResultOutputSize: String {
        ByteCountFormatter.string(
            fromByteCount: resultOutputBytes,
            countStyle: .file
        )
    }

    private var resultSavings: String {
        guard resultInputBytes > 0,
              resultOutputBytes < resultInputBytes
        else { return "0%" }
        return "\(Int((1 - Double(resultOutputBytes) / Double(resultInputBytes)) * 100))%"
    }

    private func toggle(_ id: UUID) {
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(id)
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

    private func runCompression() async {
        let sources = selectedRecords
        guard !sources.isEmpty else {
            operationTask = nil
            return
        }

        results = []
        completedCount = 0
        hasCompletedBatch = false
        defer {
            currentRecordID = nil
            operationTask = nil
            if !Task.isCancelled, !results.isEmpty {
                hasCompletedBatch = true
            }
        }

        for source in sources {
            if Task.isCancelled { break }
            currentRecordID = source.id
            var issue: PDFBatchDeliveryIssue?
            let created = await model.createCompressedCopy(
                recordID: source.id,
                quality: quality,
                presentsFeedback: false
            ) {
                issue = $0
            }
            results.append(
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
        model.noticeMessage = AppLocalization.format(
            "%lld compressed cop%@ ready",
            successfulCount,
            successfulCount == 1 ? "y" : "ies"
        )
    }
}

struct CompressionSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let onCreated: (DocumentRoute) -> Void
    @State private var quality: PDFCompressionQuality = .balanced
    @State private var operationTask: Task<Void, Never>?
    @State private var estimate: PDFCompressionEstimate?
    @State private var estimateFailed = false

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
                            WorkflowCommandHeader(
                                eyebrow: "COMPRESSION WORKFLOW",
                                title: "Create smaller copy",
                                detail: "Choose the balance between visual detail and file size.",
                                symbol: "arrow.down.right.and.arrow.up.left",
                                tint: PPColor.accent,
                                metrics: [
                                    WorkflowMetric(
                                        value: record.profile.formattedSize,
                                        label: "Current",
                                        symbol: "internaldrive",
                                        tint: PPColor.textSecondary
                                    ),
                                    WorkflowMetric(
                                        value: estimate?.formattedSize
                                            ?? (estimateFailed
                                                ? "Unavailable"
                                                : "Checking"),
                                        label: "Estimated",
                                        symbol: "chart.line.downtrend.xyaxis",
                                        tint: estimate?.savingsPercent == nil
                                            ? PPColor.amber
                                            : PPColor.mint
                                    ),
                                    WorkflowMetric(
                                        value: estimate?.savingsPercent.map {
                                            "\($0)%"
                                        } ?? "—",
                                        label: "Saved",
                                        symbol: "percent",
                                        tint: PPColor.mint
                                    )
                                ]
                            )

                            WorkflowSectionHeader(
                                eyebrow: "OUTPUT INTENT",
                                title: quality.title
                            )
                            Picker("Output quality", selection: $quality) {
                                ForEach(
                                    PDFCompressionQuality.allCases
                                ) { option in
                                    Text(option.title.localizedUI)
                                        .tag(option)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(quality.detail.localizedUI)
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                                .lineLimit(2)

                            if let estimate {
                                Label(
                                    estimate.summary,
                                    systemImage: "info.circle"
                                )
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                            }

                            if let progress = model.progress(
                                for: recordID
                            ) {
                                LocalOperationProgressView(
                                    progress: progress
                                )
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
                        operationTask = Task {
                            defer { operationTask = nil }
                            if let created = await model.createCompressedCopy(
                                recordID: recordID,
                                quality: quality
                            ) {
                                dismiss()
                                onCreated(DocumentRoute(recordID: created.id))
                            }
                        }
                    } label: {
                        Label(
                            operationTask == nil
                                ? "Create Compressed Copy"
                                : "Compressing",
                            systemImage: operationTask == nil
                                ? "arrow.down.right.and.arrow.up.left"
                                : "hourglass"
                        )
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .disabled(operationTask != nil)
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
                                : "Stop"
                        ).localizedUI
                    ) {
                        operationTask?.cancel()
                        operationTask = nil
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            operationTask?.cancel()
        }
        .task(id: quality) {
            estimate = nil
            estimateFailed = false
            do {
                estimate = try await model.compressionEstimate(
                    recordID: recordID,
                    quality: quality
                )
            } catch is CancellationError {
                return
            } catch {
                estimateFailed = true
            }
        }
    }
}

struct ProtectionSheet: View {
    private enum PermissionProfile: String, CaseIterable, Identifiable {
        case restricted
        case review
        case flexible

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let onCreated: (DocumentRoute) -> Void
    @State private var password = ""
    @State private var confirmation = ""
    @State private var permissions = PDFProtectionPermissions.restricted
    @State private var permissionProfile = PermissionProfile.restricted
    @State private var operationTask: Task<Void, Never>?

    private var validationMessage: String? {
        if password.isEmpty && confirmation.isEmpty { return nil }
        if password.count < 8 { return "Use at least eight characters." }
        if password != confirmation { return "Passwords do not match." }
        return nil
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
                            title: "Create protected copy",
                            detail: "The current working copy remains unchanged.",
                            symbol: "lock.doc",
                            tint: PPColor.amber,
                            metrics: [
                                WorkflowMetric(
                                    value: password.count >= 8
                                        && password == confirmation
                                        ? "Ready"
                                        : "Required",
                                    label: "Password",
                                    symbol: "key",
                                    tint: password.count >= 8
                                        && password == confirmation
                                        ? PPColor.mint
                                        : PPColor.amber
                                ),
                                WorkflowMetric(
                                    value: "\(allowedPermissionCount)",
                                    label: "Allowed",
                                    symbol: "checkmark.circle",
                                    tint: PPColor.cyan
                                ),
                                WorkflowMetric(
                                    value: permissionProfile.title,
                                    label: "Profile",
                                    symbol: "slider.horizontal.3",
                                    tint: PPColor.accent
                                )
                            ]
                        )

                        WorkflowSectionHeader(
                            eyebrow: "OPEN PASSWORD",
                            title: "Required to open"
                        )
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Confirm password", text: $confirmation)
                        .textContentType(.newPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let validationMessage {
                        Text(validationMessage.localizedUI)
                            .font(.caption)
                            .foregroundStyle(PPColor.amber)
                    }
                        Text(
                            "PaperPath does not store this password. Losing it can make the new copy inaccessible."
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)

                        WorkflowSectionHeader(
                            eyebrow: "PERMISSIONS",
                            title: "Allowed after opening",
                            count: allowedPermissionCount,
                            tint: PPColor.cyan
                        )
                        Picker(
                            "Permission profile",
                            selection: $permissionProfile
                        ) {
                            ForEach(PermissionProfile.allCases) { profile in
                                Text(profile.title.localizedUI)
                                    .tag(profile)
                            }
                        }
                        .pickerStyle(.segmented)

                    Toggle(
                        "Print",
                        isOn: $permissions.allowsPrinting
                    )
                    Toggle(
                        "Copy text and images",
                        isOn: $permissions.allowsCopying
                    )
                    Toggle(
                        "Comments and annotations",
                        isOn: Binding(
                            get: {
                                permissions.allowsCommenting
                            },
                            set: { enabled in
                                permissions.allowsCommenting = enabled
                                if enabled {
                                    permissions.allowsFormFilling = true
                                }
                            }
                        )
                    )
                    Toggle(
                        "Fill forms",
                        isOn: $permissions.allowsFormFilling
                    )
                    .disabled(permissions.allowsCommenting)
                    Toggle(
                        "Insert, remove, or rotate pages",
                        isOn: $permissions.allowsPageChanges
                    )
                        Text(
                            "Accessibility text access remains enabled. A separate owner key enforces permissions and is not stored."
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)

                    if let progress = model.progress(for: recordID) {
                        LocalOperationProgressView(progress: progress)
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
                        operationTask = Task {
                            defer { operationTask = nil }
                            if let created = await model.createProtectedCopy(
                                recordID: recordID,
                                password: password,
                                permissions: permissions
                            ) {
                                dismiss()
                                onCreated(DocumentRoute(recordID: created.id))
                            }
                        }
                    } label: {
                        Label(
                            operationTask == nil
                                ? "Create Protected Copy"
                                : "Protecting Copy",
                            systemImage: operationTask == nil
                                ? "lock.doc"
                                : "hourglass"
                        )
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .disabled(
                        validationMessage != nil
                            || password.isEmpty
                            || operationTask != nil
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
                                : "Stop"
                        ).localizedUI
                    ) {
                        if let operationTask {
                            operationTask.cancel()
                            self.operationTask = nil
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: password) { _, value in
                if value.count > 128 {
                    password = String(value.prefix(128))
                }
            }
            .onChange(of: confirmation) { _, value in
                if value.count > 128 {
                    confirmation = String(value.prefix(128))
                }
            }
            .onChange(of: permissionProfile) { _, profile in
                applyPermissionProfile(profile)
            }
        }
        .onDisappear {
            operationTask?.cancel()
        }
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

    let recordID: UUID
    @Binding var marks: [PDFRedactionMark]
    let onCreated: (DocumentRoute) -> Void
    @State private var operationTask: Task<Void, Never>?
    @State private var pageGroups: [PageGroup] = []
    @State private var totalCoverage = 0.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: PPSpacing.large) {
                        WorkflowCommandHeader(
                            eyebrow: "REDACTION WORKFLOW",
                            title: "Review marked areas",
                            detail: "Covered content is removed from a separate rasterized copy.",
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
                                ),
                                WorkflowMetric(
                                    value: "Removed",
                                    label: "Text layer",
                                    symbol: "text.badge.xmark",
                                    tint: PPColor.mint
                                ),
                                WorkflowMetric(
                                    value:
                                        "\(Int(totalCoverage * 100))%",
                                    label: "Marked area",
                                    symbol: "percent",
                                    tint: PPColor.cyan
                                )
                            ]
                        )

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
                                        "\(group.marks.count) area\(group.marks.count == 1 ? "" : "s")"
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
                                        Image(
                                            systemName:
                                                "selection.pin.in.out"
                                        )
                                        .foregroundStyle(
                                            PPColor.textSecondary
                                        )
                                        .frame(width: 28)
                                        VStack(
                                            alignment: .leading,
                                            spacing: 3
                                        ) {
                                            Text(
                                                "Area \(localIndex + 1)"
                                            )
                                            .font(
                                                .body.weight(.semibold)
                                            )
                                            Text(
                                                "\(Int(mark.normalizedWidth * 100))×\(Int(mark.normalizedHeight * 100))% · x\(Int(mark.normalizedX * 100)) y\(Int(mark.normalizedY * 100))"
                                            )
                                            .font(
                                                .caption2
                                                    .monospacedDigit()
                                            )
                                            .foregroundStyle(
                                                PPColor.textSecondary
                                            )
                                        }
                                        Spacer()
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
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(
                                            "Remove marked area \(localIndex + 1)"
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
                            Button("Mark Another Area") {
                                dismiss()
                            }
                            .buttonStyle(PPQuietButtonStyle())
                            Spacer()
                            Button("Clear Marks", role: .destructive) {
                                marks.removeAll()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    operationTask = Task {
                        defer { operationTask = nil }
                        if let created = await model.createRedactedCopy(
                            recordID: recordID,
                            marks: marks
                        ) {
                            guard !Task.isCancelled else { return }
                            dismiss()
                            onCreated(DocumentRoute(recordID: created.id))
                        }
                    }
                } label: {
                    if operationTask == nil {
                        Label("Create Secure Redacted Copy", systemImage: "checkmark.shield")
                    } else {
                        Label("Applying Redactions", systemImage: "hourglass")
                    }
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(marks.isEmpty || operationTask != nil)
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
                                : "Stop"
                        ).localizedUI
                    ) {
                        if operationTask != nil {
                            operationTask?.cancel()
                            operationTask = nil
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            refreshMarkGroups()
        }
        .onChange(of: marks) {
            refreshMarkGroups()
        }
        .onDisappear {
            operationTask?.cancel()
        }
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
        totalCoverage = min(
            1,
            cleaned.reduce(0) {
                $0
                    + $1.normalizedWidth
                    * $1.normalizedHeight
            }
        )
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

    let recordID: UUID
    let onCreated: (DocumentRoute) -> Void

    private let defaultOptions: PDFBookletOptions

    @State private var options: PDFBookletOptions
    @State private var assessment: PDFBookletAssessment?
    @State private var reviewMode = ReviewMode.all
    @State private var assessmentTask: Task<Void, Never>?
    @State private var creationTask: Task<Void, Never>?
    @State private var assessmentGeneration = 0
    @State private var optionFeedback = 0
    @State private var successFeedback = 0

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
                        (isBusy ? "Stop" : "Cancel").localizedUI
                    ) {
                        if isBusy {
                            stopWork()
                        } else {
                            dismiss()
                        }
                    }
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
                    .disabled(isBusy || options == defaultOptions)
                }
            }
        }
        .onAppear {
            startAssessment(debounced: false)
        }
        .onChange(of: options) { _, _ in
            optionFeedback += 1
            startAssessment(debounced: true)
        }
        .onDisappear {
            assessmentGeneration += 1
            assessmentTask?.cancel()
            creationTask?.cancel()
        }
        .interactiveDismissDisabled(creationTask != nil)
        .sensoryFeedback(.selection, trigger: optionFeedback)
        .sensoryFeedback(.success, trigger: successFeedback)
    }

    private var bookletHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "BOOKLET IMPOSITION",
            title: "Arrange pages for folding",
            detail:
                "Every front, back, page slot, and inserted blank stays visible before export.",
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
            Picker("Sheet", selection: $options.paperTarget) {
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
            .pickerStyle(.segmented)
        }
        .frame(minWidth: 260)
    }

    private var bindingControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "BINDING")
            Picker(
                "Binding",
                selection: $options.bindingEdge
            ) {
                ForEach(PDFBookletBindingEdge.allCases) { edge in
                    Text(edge.title.localizedUI).tag(edge)
                }
            }
            .pickerStyle(.segmented)
        }
        .frame(minWidth: 260)
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
            Picker(
                "Signature",
                selection: $options.signatureSheetLimit
            ) {
                Text("All pages".localizedUI).tag(0)
                Text("4 sheets".localizedUI).tag(4)
                Text("8 sheets".localizedUI).tag(8)
                Text("12 sheets".localizedUI).tag(12)
            }
            .pickerStyle(.segmented)
        }
        .frame(minWidth: 280)
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
                    .lineLimit(1)
                Text(detail.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
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
                PPEmptyState(
                    kind: .workspace,
                    title: "Booklet evidence unavailable",
                    message: "Reset or change an option to recalculate."
                )
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

    private var reviewPicker: some View {
        Picker("Review", selection: $reviewMode) {
            ForEach(ReviewMode.allCases) { mode in
                Text(mode.title.localizedUI).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var spreadColumns: [GridItem] {
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

    private func spreadRow(
        _ spread: PDFBookletSpread
    ) -> some View {
        HStack(spacing: PPSpacing.medium) {
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
                HStack(spacing: PPSpacing.large) {
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
            }

            Spacer(minLength: PPSpacing.small)

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
        .accessibilityElement(children: .combine)
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
            .lineLimit(1)
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
                creationTask == nil
                    ? "Create Booklet Copy".localizedUI
                    : "Creating Booklet Copy".localizedUI,
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

    private var isBusy: Bool {
        assessmentTask != nil || creationTask != nil
    }

    private func startAssessment(
        debounced: Bool
    ) {
        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessmentTask?.cancel()
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
            let loaded = await model.bookletAssessment(
                recordID: recordID,
                options: requestedOptions
            )
            guard !Task.isCancelled,
                  generation == assessmentGeneration,
                  options == requestedOptions,
                  let loaded
            else {
                if generation == assessmentGeneration {
                    assessmentTask = nil
                }
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
        guard let assessment,
              assessment.options == options,
              model.record(id: recordID)?.contentRevisionID
                == assessment.revisionID
        else {
            startAssessment(debounced: false)
            return
        }
        let requestedOptions = options
        creationTask = Task {
            let created = await model.createBookletCopy(
                recordID: recordID,
                options: requestedOptions
            )
            guard !Task.isCancelled else {
                creationTask = nil
                return
            }
            creationTask = nil
            guard let created else { return }
            successFeedback += 1
            dismiss()
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func stopWork() {
        assessmentGeneration += 1
        assessmentTask?.cancel()
        assessmentTask = nil
        creationTask?.cancel()
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

    let recordID: UUID
    let onCreated: (DocumentRoute) -> Void

    private let defaultOptions: PDFPrintPreparationOptions

    @State private var options: PDFPrintPreparationOptions
    @State private var assessment: PDFPrintPreparationAssessment?
    @State private var reviewMode = ReviewMode.all
    @State private var assessmentTask: Task<Void, Never>?
    @State private var creationTask: Task<Void, Never>?
    @State private var assessmentGeneration = 0
    @State private var optionFeedback = 0
    @State private var successFeedback = 0

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
                            isBusy ? "Stop" : "Cancel"
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
                    .disabled(isBusy || options == defaultOptions)
                }
            }
        }
        .onAppear {
            startAssessment(debounced: false)
        }
        .onChange(of: options) { _, _ in
            optionFeedback += 1
            startAssessment(debounced: true)
        }
        .onDisappear {
            assessmentGeneration += 1
            assessmentTask?.cancel()
            creationTask?.cancel()
        }
        .interactiveDismissDisabled(creationTask != nil)
        .sensoryFeedback(.selection, trigger: optionFeedback)
        .sensoryFeedback(.success, trigger: successFeedback)
    }

    private var printHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "PRINT PREPARATION",
            title: "Standardize a separate copy",
            detail:
                "Review physical page consequences before creating a verified print-ready PDF.",
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
            Picker(
                "Paper",
                selection: $options.paperTarget
            ) {
                ForEach(PDFPrintPaperTarget.allCases) { target in
                    Text(target.title.localizedUI).tag(target)
                }
            }
            .pickerStyle(.segmented)
        }
        .frame(minWidth: 280)
    }

    private var orientationControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "ORIENTATION")
            Picker(
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
            .pickerStyle(.segmented)
            .disabled(options.paperTarget == .original)
        }
        .frame(minWidth: 260)
        .opacity(options.paperTarget == .original ? 0.58 : 1)
    }

    private var scaleModeControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "PLACEMENT")
            Picker(
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
            .pickerStyle(.segmented)
        }
        .frame(minWidth: 280)
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
            return "Content remains at 100%; oversized pages are clipped by the printable frame."
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
                PPEmptyState(
                    kind: .workspace,
                    title: "Print evidence unavailable",
                    message: "Reset or change a print option to recalculate."
                )
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

    private var reviewPicker: some View {
        Picker("Review", selection: $reviewMode) {
            ForEach(ReviewMode.allCases) { mode in
                Text(mode.title.localizedUI).tag(mode)
            }
        }
        .pickerStyle(.segmented)
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

    private func printPageRow(
        _ page: PDFPrintPreparationPage
    ) -> some View {
        HStack(spacing: PPSpacing.medium) {
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
                .lineLimit(1)
                HStack(spacing: PPSpacing.large) {
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
                HStack(spacing: PPSpacing.medium) {
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
            }

            Spacer(minLength: PPSpacing.small)

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
                "Separate PDF · annotations baked in · working copy unchanged"
                    .localizedUI
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .lineLimit(1)
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
                creationTask == nil
                    ? "Create Print-Ready Copy".localizedUI
                    : "Creating Print-Ready Copy".localizedUI,
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

    private var isBusy: Bool {
        assessmentTask != nil || creationTask != nil
    }

    private func startAssessment(
        debounced: Bool
    ) {
        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessmentTask?.cancel()
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
            let loaded = await model.printPreparationAssessment(
                recordID: recordID,
                options: requestedOptions
            )
            guard !Task.isCancelled,
                  generation == assessmentGeneration,
                  options == requestedOptions,
                  let loaded
            else {
                if generation == assessmentGeneration {
                    assessmentTask = nil
                }
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
        guard let assessment,
              assessment.options == options,
              model.record(id: recordID)?.contentRevisionID
                == assessment.revisionID
        else {
            startAssessment(debounced: false)
            return
        }
        let requestedOptions = options
        creationTask = Task {
            let created = await model.createPrintReadyCopy(
                recordID: recordID,
                options: requestedOptions
            )
            guard !Task.isCancelled else {
                creationTask = nil
                return
            }
            creationTask = nil
            guard let created else { return }
            successFeedback += 1
            dismiss()
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func stopWork() {
        assessmentGeneration += 1
        assessmentTask?.cancel()
        assessmentTask = nil
        creationTask?.cancel()
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

    let recordID: UUID
    let focus: PDFExportFocus?
    let onCreated: (DocumentRoute) -> Void
    let onReviewPage: (Int) -> Void
    @State private var shareItems: [Any] = []
    @State private var isSharing = false
    @State private var temporaryShareURLs: [URL] = []
    @State private var exportTask: Task<Void, Never>?
    @State private var exportLabel: String?
    @State private var preflight: PDFDeliveryPreflightAssessment?
    @State private var preflightError: String?
    @State private var isPreparingPrint = false
    @State private var isPreparingBooklet = false
    @State private var officeReceipt: PDFOfficeExportReceipt?
    @State private var activeOfficeFormat: PDFTextExportFormat?
    @State private var officeFailure: PDFOfficeExportFailure?
    @State private var officeRouteFeedback = 0
    @State private var officeReceiptFeedback = 0
    @State private var officeFailureFeedback = 0
    @State private var officePinFeedback = 0
    @State private var inspectedOfficeReceipt:
        PDFOfficeExportReceipt?
    @State private var selectedBatchRetrySegmentIDs: Set<UUID> = []
    @State private var isShowingAllOfficeBatchSegments = false
    @State private var showsOtherOfficeFormats = false
    @State private var showsOfficeEvidence = false
    @State private var showsPortableTextFormats = false
    @AppStorage("export.catalogMode")
    private var savedExportCatalogMode =
        ExportCatalogMode.recommended.rawValue

    init(
        recordID: UUID,
        focus: PDFExportFocus? = nil,
        onCreated: @escaping (DocumentRoute) -> Void,
        onReviewPage: @escaping (Int) -> Void = { _ in }
    ) {
        self.recordID = recordID
        self.focus = focus
        self.onCreated = onCreated
        self.onReviewPage = onReviewPage
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: PPSpacing.regular
                    ) {
                        if let record = model.record(id: recordID) {
                            exportContextHeader(record)
                        }

                        if focus == nil {
                            exportCatalogPicker
                        }

                        if let record = model.record(id: recordID),
                           record.hasCurrentDeliveryReceipt {
                            verifiedShareButton(record)
                        }

                        if focus == nil || focus == .safeShare {
                            if focus == .safeShare,
                               model.record(id: recordID)?
                                .hasCurrentDeliveryReceipt != true {
                                preflightPanel
                                if preflight?.status == .blocked
                                    || preflightError != nil {
                                    recoveryActions
                                }
                                safeShareButton
                            }
                        }

                        if focus == nil,
                           exportCatalogMode == .recommended {
                            recommendedOutputSection
                        }

                        if focus == nil,
                           exportCatalogMode == .pdf {
                            outputSection(
                                title: "PDF OUTPUTS",
                                detail: "Preserve, flatten, print, or impose",
                                symbol: "doc.richtext",
                                tint: PPColor.accent
                            ) {
                                safeShareButton

                                exportButton(
                                    "Current PDF Copy",
                                    detail: "Share the editable working copy",
                                    symbol: "doc"
                                ) {
                                    if let url = model.url(for: recordID) {
                                        share([url])
                                    }
                                }

                                exportButton(
                                    "Flattened PDF Copy",
                                    detail: "Lock annotations into an image-based copy",
                                    symbol: "square.stack.3d.down.right"
                                ) {
                                    exportTask = Task {
                                        exportLabel = "flattened copy"
                                        defer {
                                            exportTask = nil
                                            exportLabel = nil
                                        }
                                        if let created = await model.createFlattenedCopy(
                                            recordID: recordID
                                        ) {
                                            dismiss()
                                            onCreated(
                                                DocumentRoute(recordID: created.id)
                                            )
                                        }
                                    }
                                }

                                exportButton(
                                    "Print-Ready PDF",
                                    detail:
                                        "Standardize paper with trim, bleed, and safe-area evidence",
                                    symbol: "printer.fill",
                                    badge: "PDF"
                                ) {
                                    isPreparingPrint = true
                                }

                                exportButton(
                                    "Booklet PDF",
                                    detail:
                                        "Impose signatures with page order and creep evidence",
                                    symbol: "book.pages.fill",
                                    badge: "2-UP"
                                ) {
                                    isPreparingBooklet = true
                                }
                            }
                        }

                        if focus == .text
                            || (
                                focus == nil
                                    && exportCatalogMode == .office
                            ) {
                            outputSection(
                                title: "EDITABLE OFFICE",
                                detail: "Choose by structure, not extension",
                                symbol: "doc.badge.arrow.up",
                                tint: PPColor.cyan
                            ) {
                        if let officeFailure,
                           let record = model.record(id: recordID) {
                            officeExportFailurePanel(
                                officeFailure,
                                record: record
                            )
                        }
                        if let officeReceipt,
                           let record = model.record(id: recordID) {
                            officeReceiptPanel(
                                officeReceipt,
                                record: record
                            )
                        }
                        if let record = model.record(id: recordID) {
                            let portfolio = PDFOfficeExportPortfolio(
                                profile: record.profile
                            )
                            if let batchRun = model.officeBatchRun(
                                for: recordID
                            ) {
                                officeBatchRunPanel(
                                    batchRun,
                                    record: record
                                )
                            }
                            officeGuidedChoice(
                                record,
                                portfolio: portfolio
                            )
                            if showsOfficeEvidence {
                                VStack(
                                    alignment: .leading,
                                    spacing: PPSpacing.small
                                ) {
                                    officeReadinessStrip(
                                        record,
                                        portfolio: portfolio
                                    )
                                    officeDecisionStrip(portfolio)
                                    officePreflightStrip(portfolio)
                                    officeBudgetStrip(
                                        portfolio.visualBudgetPlan
                                    )
                                    officeReceiptHistory(
                                        record: record,
                                        currentReceiptID:
                                            officeReceipt?.id
                                    )
                                }
                                .transition(
                                    .move(edge: .top)
                                        .combined(with: .opacity)
                                )
                            }
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
                                        showsPortableTextFormats
                                            ? "Hide text-only formats"
                                            : "Need RTF, Markdown, or plain text?",
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
                                .frame(minHeight: 40)
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

                        if focus == .images
                            || (
                                focus == nil
                                    && exportCatalogMode == .images
                            ) {
                            outputSection(
                                title: "PAGE IMAGES",
                                detail: "Rendered appearance by resolution",
                                symbol: "photo.on.rectangle.angled",
                                tint: PPColor.amber
                            ) {
                                ForEach(
                                    PDFPageImageExportPreset.allCases
                                ) { preset in
                                    exportButton(
                                        preset.title,
                                        detail: preset.detail,
                                        symbol: preset.symbol,
                                        badge: pageImageBadge(preset)
                                    ) {
                                        exportTask = Task {
                                            exportLabel = preset.title.lowercased()
                                            defer {
                                                exportTask = nil
                                                exportLabel = nil
                                            }
                                            let urls = await model
                                                .makePageImageExports(
                                                    recordID: recordID,
                                                    preset: preset
                                                )
                                            if !urls.isEmpty {
                                                share(
                                                    urls,
                                                    temporaryURLs: urls
                                                )
                                            }
                                        }
                                    }
                                }
                            }

                            outputSection(
                                title: "EMBEDDED ASSETS",
                                detail: "Original image streams",
                                symbol: "photo.stack",
                                tint: PPColor.mint
                            ) {
                                exportButton(
                                    "Embedded Images",
                                    detail: "Original JPEG/JP2 streams and lossless decoded PNGs",
                                    symbol: "photo.stack",
                                    badge: "ASSETS"
                                ) {
                                    exportTask = Task {
                                        exportLabel = "embedded images"
                                        defer {
                                            exportTask = nil
                                            exportLabel = nil
                                        }
                                        let urls = await model
                                            .makeEmbeddedImageExports(
                                                recordID: recordID
                                            )
                                        if !urls.isEmpty {
                                            share(
                                                urls,
                                                temporaryURLs: urls
                                            )
                                        }
                                    }
                                }
                                .accessibilityIdentifier(
                                    "exportEmbeddedImages"
                                )
                            }
                        }

                        if let exportLabel {
                            if model.officeBatchRun(for: recordID) != nil {
                                EmptyView()
                            } else if let activeOfficeFormat,
                               let record = model.record(id: recordID) {
                                officeExportProgressPanel(
                                    exportLabel,
                                    format: activeOfficeFormat,
                                    record: record
                                )
                            } else {
                                if let progress = model.progress(for: recordID) {
                                    LocalOperationProgressView(progress: progress)
                                } else {
                                    HStack(spacing: PPSpacing.medium) {
                                        ProgressView()
                                        Text("Preparing \(exportLabel) on device")
                                            .font(.subheadline)
                                            .foregroundStyle(PPColor.textSecondary)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(navigationTitle.localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        (
                            exportTask == nil
                                ? "Done"
                                : "Stop"
                        ).localizedUI
                    ) {
                        if let exportTask {
                            exportTask.cancel()
                        } else {
                            dismiss()
                        }
                    }
                        .disabled(
                            exportTask == nil
                                && model.isProcessing(recordID)
                        )
                }
            }
        }
        .sheet(isPresented: $isSharing) {
            ShareSheet(items: shareItems)
        }
        .sheet(item: $inspectedOfficeReceipt) { receipt in
            OfficeEvidenceInspectorView(
                receipt: receipt,
                currentRevisionID: model.record(id: recordID)?
                    .contentRevisionID
            )
        }
        .fullScreenCover(isPresented: $isPreparingPrint) {
            PrintPreparationSheet(recordID: recordID) { route in
                isPreparingPrint = false
                dismiss()
                onCreated(route)
            }
        }
        .fullScreenCover(isPresented: $isPreparingBooklet) {
            BookletPreparationSheet(recordID: recordID) { route in
                isPreparingBooklet = false
                dismiss()
                onCreated(route)
            }
        }
        .task(id: recordID) {
            guard focus == .safeShare else { return }
            await model.updateTaskCheckpoint(
                recordID: recordID,
                checkpoint: DocumentTaskCheckpoint(stage: .verify)
            )
            await loadPreflight()
        }
        .onChange(of: isSharing) { _, sharing in
            if !sharing {
                cleanupTemporaryExports()
            }
        }
        .onDisappear {
            if !isSharing {
                exportTask?.cancel()
                cleanupTemporaryExports()
            }
        }
        .sensoryFeedback(.selection, trigger: officeRouteFeedback)
        .sensoryFeedback(.success, trigger: officeReceiptFeedback)
        .sensoryFeedback(.error, trigger: officeFailureFeedback)
        .sensoryFeedback(.selection, trigger: officePinFeedback)
        .sensoryFeedback(
            .selection,
            trigger: savedExportCatalogMode
        )
        .interactiveDismissDisabled(exportTask != nil)
    }

    private var navigationTitle: String {
        switch focus {
        case .safeShare: return "Verify & Share"
        case .text: return "PDF to Office"
        case .images: return "PDF to Images"
        case nil: return "Export"
        }
    }

    private var officeFormats: [PDFTextExportFormat] {
        [.wordDocument, .excelWorkbook, .powerPointPresentation]
    }

    private var portableTextFormats: [PDFTextExportFormat] {
        [.richText, .markdown, .plainText]
    }

    private var exportCatalogMode: ExportCatalogMode {
        ExportCatalogMode(rawValue: savedExportCatalogMode)
            ?? .recommended
    }

    private var exportCatalogPicker: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "OUTPUT INSTRUMENT",
                detail: "Choose the delivery contract first",
                symbol: "dial.medium",
                tint: PPColor.rose
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    ForEach(ExportCatalogMode.allCases) { mode in
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
                    ForEach(ExportCatalogMode.allCases) { mode in
                        exportCatalogButton(mode)
                    }
                }
            }
        }
        .accessibilityIdentifier("exportCatalogMode")
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
                savedExportCatalogMode = mode.rawValue
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
                    .lineLimit(1)
                Text(exportCatalogDetail(mode).localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
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
        .accessibilityValue(selected ? "Selected" : "")
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

    private func exportCatalogDetail(
        _ mode: ExportCatalogMode
    ) -> String {
        switch mode {
        case .recommended: return "Best route"
        case .pdf: return "Final copy"
        case .office: return "Editable"
        case .images: return "Rendered"
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
    private var recommendedOutputSection: some View {
        outputSection(
            title: "RECOMMENDED ROUTES",
            detail: "Matched to this PDF",
            symbol: "target",
            tint: PPColor.mint
        ) {
            if model.record(id: recordID)?
                .hasCurrentDeliveryReceipt != true {
                safeShareButton
            }

            if let record = model.record(id: recordID) {
                let portfolio = PDFOfficeExportPortfolio(
                    profile: record.profile
                )
                if let plan = portfolio.recommendedPlan {
                    officeAlternativeChoice(
                        plan,
                        canReconstruct: !portfolio.isProtected
                    )
                }
            }

            exportButton(
                "Print-Ready PDF",
                detail:
                    "Standardize paper with trim, bleed, and safe-area evidence",
                symbol: "printer.fill",
                badge: "PDF"
            ) {
                isPreparingPrint = true
            }
        }
    }

    private func outputSection<Content: View>(
        title: String,
        detail: String,
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
        let detail: String
        let symbol: String
        let tint: Color
        switch focus {
        case .safeShare:
            title = "Prepare trusted delivery"
            detail = "Review the working copy before creating a verified result."
            symbol = "checkmark.shield"
            tint = PPColor.mint
        case .text:
            title = "What will you do with the result?"
            detail = "PaperPath recommends a format from this PDF’s actual structure."
            symbol = "doc.badge.arrow.up"
            tint = PPColor.accent
        case .images:
            title = "Choose rendered pages or assets"
            detail = "Rendered pages preserve appearance; assets preserve source images."
            symbol = "photo.stack"
            tint = PPColor.cyan
        case nil:
            title = "Choose an output"
            detail = "Create, convert, or verify without changing this working copy."
            symbol = "square.and.arrow.up"
            tint = PPColor.accent
        }

        return WorkflowCommandHeader(
            eyebrow: "OUTPUT WORKFLOW",
            title: title,
            detail: detail,
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
                        "\(Int(record.profile.textCoverage * 100))%",
                    label: "Text",
                    symbol: "text.magnifyingglass",
                    tint: record.profile.textCharacterCount > 0
                        ? PPColor.mint
                        : PPColor.amber
                ),
                WorkflowMetric(
                    value: record.profile.formattedSize,
                    label: "Source",
                    symbol: "internaldrive",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: "Local",
                    label: "Conversion",
                    symbol: "iphone",
                    tint: PPColor.mint
                )
            ]
        )
    }

    private func verifiedShareButton(
        _ record: DocumentRecord
    ) -> some View {
        Button {
            if let url = model.url(for: record.id) {
                share([url])
            }
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
            "Shares this already verified PDF without creating another copy"
        )
        .accessibilityIdentifier("shareVerifiedPDF")
    }

    private var safeShareButton: some View {
        Button {
            exportTask = Task {
                exportLabel = "verified copy"
                defer {
                    exportTask = nil
                    exportLabel = nil
                }
                if let created = await model.createSafeShareCopy(
                    recordID: recordID
                ) {
                    dismiss()
                    onCreated(DocumentRoute(recordID: created.id))
                }
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
                        Text("Verified Copy")
                            .font(.headline)
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                        Text("VERIFY")
                            .font(.caption2.smallCaps().weight(.bold))
                            .foregroundStyle(PPColor.mint)
                    }
                    Text(
                        "Create, reopen, and issue a SHA-256 receipt."
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
                    focus == .safeShare
                        && (
                            preflight == nil
                                || preflight?.status == .blocked
                        )
                )
        )
        .accessibilityHint(
            "Creates a separate image-based PDF and verifies the result"
        )
        .accessibilityIdentifier("safeShareButton")
    }

    @ViewBuilder
    private var preflightPanel: some View {
        if let preflight {
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
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                        Text(
                            "\(preflight.pageCount) pages · \(preflight.formattedSize)"
                        )
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textSecondary)
                    }

                    Spacer()

                    if preflight.fixCount > 0 {
                        Text("\(preflight.fixCount) FIX")
                            .font(.caption2.smallCaps().weight(.bold))
                            .foregroundStyle(PPColor.accent)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(
                        Array(preflight.items.enumerated()),
                        id: \.element.id
                    ) { index, item in
                        preflightRow(item)
                        if index < preflight.items.count - 1 {
                            Rectangle()
                                .fill(PPColor.border.opacity(0.55))
                                .frame(height: 0.6)
                                .padding(.leading, 32)
                        }
                    }
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
        } else {
            HStack(spacing: PPSpacing.medium) {
                ProgressView()
                Text("Checking on device")
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
    }

    private func preflightRow(
        _ item: PDFDeliveryPreflightItem
    ) -> some View {
        Group {
            if let pageIndex = item.reviewPageIndex {
                Button {
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(180))
                        onReviewPage(pageIndex)
                    }
                } label: {
                    preflightRowContent(item, showsDisclosure: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    "Opens page \(pageIndex + 1) for review"
                )
            } else {
                preflightRowContent(item, showsDisclosure: false)
            }
        }
    }

    private func preflightRowContent(
        _ item: PDFDeliveryPreflightItem,
        showsDisclosure: Bool
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
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                    .padding(.top, 5)
            }
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .combine)
    }

    private var recoveryActions: some View {
        outputSection(
            title: "CONTINUE SAFELY",
            detail: "The working copy remains unchanged",
            symbol: "lifepreserver",
            tint: PPColor.amber
        ) {
            Button {
                if let url = model.url(for: recordID) {
                    share([url])
                }
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
            .accessibilityIdentifier("shareBlockedWorkingCopy")

            Button {
                Task { await loadPreflight() }
            } label: {
                Label("Check this PDF again", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("retryDeliveryPreflight")
        }
    }

    private func loadPreflight() async {
        preflight = nil
        preflightError = nil
        do {
            preflight = try await model.deliveryPreflight(
                recordID: recordID
            )
        } catch is CancellationError {
            return
        } catch {
            if let paperError = error as? PaperPathError,
               case .lockedPDF = paperError {
                preflightError =
                    "Unlock this PDF and create an editable private copy first."
            } else {
                preflightError =
                    "PaperPath could not reopen every page. The working copy was not changed."
            }
        }
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
        detail: String,
        symbol: String,
        badge: String? = nil,
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
                    Text(detail.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
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
        )
    }

    private func officeGuidedChoice(
        _ record: DocumentRecord,
        portfolio: PDFOfficeExportPortfolio
    ) -> some View {
        let recommended = portfolio.recommendedPlan
        let alternatives = portfolio.plans.filter {
            $0.format != recommended?.format
        }
        let canReconstruct = !portfolio.isProtected

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            if let recommended {
                SectionEyebrow(text: "BEST MATCH")
                Button {
                    startTextExport(recommended.format)
                } label: {
                    HStack(spacing: PPSpacing.medium) {
                        ToolSymbolPlate(
                            symbol: recommended.format.symbol,
                            tint: officeReadinessColor(
                                recommended.readiness
                            ),
                            size: 44
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                AppLocalization.format(
                                    "Export to %@",
                                    recommended.format.title.localizedUI
                                )
                            )
                            .font(.headline)
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            Text(
                                officePurposeLine(recommended.format)
                                    .localizedUI
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: PPSpacing.small)
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(
                                officeReadinessColor(
                                    recommended.readiness
                                )
                            )
                    }
                    .padding(.vertical, PPSpacing.small)
                    .padding(.horizontal, PPSpacing.small)
                    .frame(minHeight: 66)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(
                                officeReadinessColor(
                                    recommended.readiness
                                )
                            )
                            .frame(width: 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(
                    !canReconstruct
                        || model.isProcessing(recordID)
                        || exportTask != nil
                )
                .accessibilityHint(
                    officeCompatibilityLine(recommended.format)
                        .localizedUI
                )
                .accessibilityIdentifier("recommendedOfficeExport")

                Label(
                    officeCompatibilityLine(recommended.format)
                        .localizedUI,
                    systemImage: "checkmark.shield"
                )
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !canReconstruct {
                Label(
                    "This PDF blocks editable reconstruction. Open an unlocked private copy before converting."
                        .localizedUI,
                    systemImage:
                        "lock.trianglebadge.exclamationmark"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, PPSpacing.xSmall)
            }

            Button {
                withAnimation(
                    reduceMotion ? nil : .snappy(duration: 0.2)
                ) {
                    showsOtherOfficeFormats.toggle()
                }
            } label: {
                HStack {
                    Label(
                        showsOtherOfficeFormats
                            ? "Hide other Office formats"
                            : "Choose another Office format",
                        systemImage: "square.grid.2x2"
                    )
                    Spacer()
                    Image(
                        systemName: showsOtherOfficeFormats
                            ? "chevron.up"
                            : "chevron.down"
                    )
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsOtherOfficeFormats {
                VStack(spacing: 0) {
                    ForEach(alternatives) { plan in
                        officeAlternativeChoice(
                            plan,
                            canReconstruct: canReconstruct
                        )
                    }
                }
                .transition(
                    .move(edge: .top).combined(with: .opacity)
                )
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
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                showsOfficeEvidence ? "Expanded" : "Collapsed"
            )
        }
        .padding(.vertical, PPSpacing.xSmall)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppLocalization.format(
                "Office format guidance for %@",
                record.displayName
            )
        )
    }

    private func officeAlternativeChoice(
        _ plan: PDFOfficeExportFormatPlan,
        canReconstruct: Bool
    ) -> some View {
        Button {
            startTextExport(plan.format)
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
            return "DOCX structure is rebuilt locally; Word or Pages may reflow complex layouts."
        case .excelWorkbook:
            return "XLSX rows are inferred from PDF spacing; review complex tables after opening."
        case .powerPointPresentation:
            return "PPTX preserves page appearance with searchable text; slide content is not fully editable."
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
                            "\(plan.decisionRole) · \(plan.compactEvidence) · \(portfolio.productionSLA.window)"
                                .localizedUI
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
            "\(portfolio.embeddedAuditSummary). \(portfolio.outputBoundaryLine)"
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
                        "Fallback \($0.fileExtension.uppercased())"
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
                dismiss()
                onCreated(
                    DocumentRoute(
                        recordID: recordID,
                        quickTask: targetQuickTask
                    )
                )
            } else if action.id == "ocr" {
                dismiss()
                onCreated(
                    DocumentRoute(
                        recordID: recordID,
                        quickTask: .recognizeText
                    )
                )
            } else {
                model.noticeMessage = action.detail
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
                    Text("Building \(format.fileExtension.uppercased())".localizedUI)
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
            "Preparing \(format.title) on device"
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

        return HStack(alignment: .top, spacing: PPSpacing.small) {
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
                .lineLimit(2)
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
                            .frame(width: 28, height: 28)
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
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        failure.kind.title.localizedUI
                    )
                }
            }
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
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Office preflight \(summary)"
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(signal.title.localizedUI)
                    .font(.caption2.smallCaps())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 86, alignment: .leading)
        .help(signal.detail.localizedUI)
    }

    private func officeBudgetStrip(
        _ plan: PDFOfficeVisualBudgetPlan
    ) -> some View {
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
                    tint: officeBudgetPressureColor(plan.budgetPressure)
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
            VStack(alignment: .leading, spacing: PPSpacing.small) {
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
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Office visual budget \(plan.mode.title), \(plan.anchorPolicy.title), \(plan.formattedPerPageBudget) per visual reference"
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
                    .lineLimit(1)
                Text(label.localizedUI)
                    .font(.caption2.smallCaps())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 82, alignment: .leading)
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
                .symbolEffect(.bounce, value: officeReceiptFeedback)
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
                        "\(evidence.yieldSummary) · \(evidence.primaryUnitCount) \(evidence.primaryUnitLabel)"
                            .localizedUI
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
            "Office export \(receipt.format.title), \(receipt.receiptSummary), \(receipt.embeddedEvidenceLabel)"
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
            "Recent Office export \(receipt.format.title), \(receipt.receiptSummary), \(receipt.embeddedEvidenceLabel)"
        )
    }

    private func officeReceiptMenu(
        _ receipt: PDFOfficeExportReceipt,
        availability: PDFOfficeArtifactAvailability
    ) -> some View {
        Menu {
            Button {
                inspectedOfficeReceipt = receipt
            } label: {
                Label(
                    "Inspect production evidence",
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
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.borderless)
        .disabled(exportTask != nil)
        .accessibilityLabel("Office output actions".localizedUI)
    }

    private func toggleOfficeExportPinned(
        _ receipt: PDFOfficeExportReceipt
    ) {
        Task {
            await model.setOfficeExportPinned(
                recordID: recordID,
                receiptID: receipt.id,
                pinned: !receipt.isPinned
            )
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
              !model.isProcessing(recordID)
        else { return }
        selectedBatchRetrySegmentIDs = []
        isShowingAllOfficeBatchSegments = false
        officeFailure = nil
        officeReceipt = nil
        exportTask = Task {
            exportLabel = "\(format.title.lowercased()) batch"
            activeOfficeFormat = format
            defer {
                exportTask = nil
                exportLabel = nil
                activeOfficeFormat = nil
            }
            do {
                guard let run = try await model.makeOfficeBatch(
                    recordID: recordID,
                    format: format
                ) else {
                    officeFailure = PDFOfficeExportFailure(
                        format: format,
                        kind: .unknown,
                        detail:
                            "This PDF is no longer available for segmented export."
                    )
                    officeFailureFeedback += 1
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
        exportTask = Task {
            exportLabel = AppLocalization.format(
                "retrying %lld Office part%@",
                targetIDs.count,
                targetIDs.count == 1 ? "" : "s"
            )
            activeOfficeFormat = run.plan.format
            defer {
                exportTask = nil
                exportLabel = nil
                activeOfficeFormat = nil
                selectedBatchRetrySegmentIDs = []
            }
            do {
                guard let result = try await model.resumeOfficeBatch(
                    recordID: recordID,
                    selectedSegmentIDs: targetIDs
                ) else {
                    officeFailure = PDFOfficeExportFailure(
                        format: run.plan.format,
                        kind: .sourceChanged,
                        detail:
                            "This batch no longer matches the current PDF. Start a new export."
                    )
                    officeFailureFeedback += 1
                    return
                }
                if result.completedCount > 0 {
                    officeReceipt = model.record(id: recordID)?
                        .officeReceipts
                        .first { $0.batchID == result.id }
                    officeReceiptFeedback += 1
                }
            } catch is CancellationError {
                return
            } catch {
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
        exportTask = Task {
            defer { exportTask = nil }
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
            var urls: [URL] = []
            for receipt in receipts {
                guard !Task.isCancelled else { return }
                if let url = await model.reusableOfficeExportURL(
                    recordID: recordID,
                    receipt: receipt
                ) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else {
                officeFailure = .unavailableArtifact(
                    format: run.plan.format
                )
                officeFailureFeedback += 1
                return
            }
            if urls.count < run.completedCount {
                model.noticeMessage = AppLocalization.format(
                    "%lld of %lld retained parts are available",
                    urls.count,
                    run.completedCount
                )
            }
            share(urls)
        }
    }

    private func shareOfficeBatchArchive(
        _ run: PDFOfficeBatchRun
    ) {
        guard exportTask == nil,
              !model.isProcessing(recordID)
        else { return }
        exportTask = Task {
            exportLabel = "batch ZIP"
            defer {
                exportTask = nil
                exportLabel = nil
            }
            do {
                let archive = try await model.makeOfficeBatchArchive(
                    recordID: recordID,
                    batchID: run.id
                )
                share([archive], temporaryURLs: [archive])
            } catch is CancellationError {
                return
            } catch {
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
                            alignment: .leading
                        )
                        .padding(.vertical, 4)
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
                            alignment: .leading
                        )
                        .padding(.vertical, 4)
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
                            shareOfficeBatch(run)
                        } label: {
                            Label(
                                run.completedCount == run.segments.count
                                    ? "Share all parts"
                                    : "Share completed parts",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                        .disabled(
                            run.completedCount == 0
                                || exportTask != nil
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
                        Button {
                            shareOfficeBatchArchive(run)
                        } label: {
                            Label(
                                "Share one ZIP",
                                systemImage: "archivebox"
                            )
                        }
                    } label: {
                        Label(
                            "Deliver",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        run.completedCount == 0
                            || exportTask != nil
                    )

                    Spacer(minLength: 0)

                    if run.isFinished {
                        Button {
                            Task {
                                await model.clearFinishedOfficeBatch(
                                    recordID: recordID
                                )
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
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
            "\(run.status.title), \(run.completedCount) of \(run.segments.count) parts ready"
        )
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
            .frame(minHeight: 28)
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
                                "\(plan.riskEvidence) · \(plan.compactEvidence)"
                                    .localizedUI
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
              !model.isProcessing(recordID)
        else { return }
        let profile = model.record(id: recordID)?.profile ?? .empty
        if format.officePageLimit.map({
            profile.pageCount > $0
        }) == true {
            startOfficeBatch(format)
            return
        }
        let portfolio = PDFOfficeExportPortfolio(profile: profile)
        let plan = portfolio.plan(for: format)
        let budgetPlan = portfolio.visualBudgetPlan
        exportTask = Task {
            exportLabel = format.title.lowercased()
            activeOfficeFormat = format.isOfficeFormat
                ? format
                : nil
            if format.isOfficeFormat {
                officeReceipt = nil
                officeFailure = nil
            }
            defer {
                exportTask = nil
                exportLabel = nil
                activeOfficeFormat = nil
            }
            do {
                let artifact = try await model.makeTextExport(
                    recordID: recordID,
                    format: format
                )
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
                let receipt = PDFOfficeExportReceipt(
                    format: format,
                    fileName: artifact.url.lastPathComponent,
                    fileSizeBytes: Int64(size),
                    plan: plan,
                    budgetPlan: budgetPlan,
                    portfolio: portfolio,
                    runtimeEvidence: artifact.runtimeEvidence
                )
                let retained = await model.retainOfficeExport(
                    recordID: recordID,
                    receipt: receipt,
                    sourceURL: artifact.url
                )
                officeReceipt = retained?.receipt ?? receipt
                officeReceiptFeedback += 1
                if let retained {
                    share([retained.url])
                } else {
                    share(
                        [artifact.url],
                        temporaryURLs: [artifact.url]
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if format.isOfficeFormat {
                    officeFailure = .classify(
                        format: format,
                        error: error
                    )
                } else {
                    model.errorMessage = error.localizedDescription
                }
                officeFailureFeedback += 1
            }
        }
    }

    private func shareRetainedOfficeExport(
        _ receipt: PDFOfficeExportReceipt
    ) {
        guard exportTask == nil,
              !model.isProcessing(recordID)
        else { return }
        exportTask = Task {
            defer { exportTask = nil }
            if let url = await model.reusableOfficeExportURL(
                recordID: recordID,
                receipt: receipt
            ) {
                share([url])
            } else if !Task.isCancelled {
                officeFailure = .unavailableArtifact(
                    format: receipt.format
                )
                officeFailureFeedback += 1
            }
        }
    }

    private func openOfficeRecoveryTask(
        _ quickTask: PDFQuickTask
    ) {
        officeFailure = nil
        dismiss()
        onCreated(
            DocumentRoute(
                recordID: recordID,
                quickTask: quickTask
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
        temporaryURLs: [URL] = []
    ) {
        cleanupTemporaryExports()
        shareItems = items
        temporaryShareURLs = temporaryURLs
        isSharing = true
    }

    private func cleanupTemporaryExports() {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .standardizedFileURL.path
        let directories = Set(
            temporaryShareURLs.compactMap { url -> URL? in
                let standardized = url.standardizedFileURL
                guard standardized.path.hasPrefix(temporaryRoot) else {
                    return nil
                }
                let parent = standardized.deletingLastPathComponent()
                let name = parent.lastPathComponent
                return name.hasPrefix("PaperPath-Images-")
                    || name.hasPrefix("PaperPath-EmbeddedImages-")
                    || name.hasPrefix("PaperPath-Office-Batch-")
                    || name.hasPrefix("PaperPath-Office-Export-")
                    ? parent
                    : nil
            }
        )
        for url in temporaryShareURLs {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(temporaryRoot),
                  !directories.contains(
                    standardized.deletingLastPathComponent()
                  )
            else { continue }
            try? fileManager.removeItem(at: standardized)
        }
        for directory in directories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryShareURLs = []
        shareItems = []
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
                WorkflowCommandHeader(
                    eyebrow: "OFFICE PRODUCTION AUDIT V31",
                    title: receipt.format.title,
                    detail: receipt.routeSummary,
                    symbol: receipt.routeConfidence.symbol,
                    tint: confidenceColor,
                    metrics: headerMetrics
                )
                .listRowInsets(
                    EdgeInsets(
                        top: PPSpacing.small,
                        leading: PPSpacing.regular,
                        bottom: PPSpacing.small,
                        trailing: PPSpacing.regular
                    )
                )
                .listRowBackground(Color.clear)

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
            .navigationTitle("Production evidence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 3
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
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 3
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

    let onOpenDocument: (DocumentRoute) -> Void

    @State private var selectedIDs = Set<UUID>()
    @State private var items: [UUID: PDFBatchDeliveryItem] = [:]
    @State private var phase: Phase = .selecting
    @State private var batchTask: Task<Void, Never>?
    @State private var isSharing = false
    @State private var didInitialize = false
    @State private var wasStopped = false
    @State private var batchRunID = UUID()
    @State private var batchStartedAt = Date()
    @State private var batchPersistenceTask: Task<Void, Never>?
    @State private var resultFilter: ResultFilter = .all
    @State private var selectedIssueItem: PDFBatchDeliveryItem?
    @State private var isConfirmingStopAndClose = false

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

                        if phase == .selecting {
                            selectionControls
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
                            phase == .finished
                                ? "Done"
                                : "Close"
                        ).localizedUI
                    ) {
                        if phase == .processing {
                            isConfirmingStopAndClose = true
                        } else {
                            dismiss()
                        }
                    }
                }
                if phase == .finished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("New") {
                            resetBatch()
                        }
                    }
                }
            }
        }
        .task {
            initializeSelectionIfNeeded()
        }
        .onDisappear {
            batchTask?.cancel()
            batchPersistenceTask?.cancel()
        }
        .sheet(isPresented: $isSharing) {
            ShareSheet(items: shareURLs.map { $0 as Any })
        }
        .sheet(item: $selectedIssueItem) { item in
            BatchDeliveryIssueView(item: item) {
                selectedIssueItem = nil
                startBatch(recordIDs: [item.sourceRecordID])
            } onOpenSource: {
                selectedIssueItem = nil
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    onOpenDocument(
                        DocumentRoute(recordID: item.sourceRecordID)
                    )
                }
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
                wasStopped = true
                batchTask?.cancel()
                dismiss()
            }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text(
                "Verified outputs stay available. Unfinished PDFs can be resumed later."
            )
        }
        .interactiveDismissDisabled(phase == .processing)
        .sensoryFeedback(.success, trigger: verifiedCount)
    }

    private var batchHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "LOCAL DELIVERY QUEUE",
            title: headerTitle,
            detail: headerDetail,
            symbol: phase == .finished
                ? "checkmark.shield.fill"
                : "checkmark.shield",
            tint: phase == .finished
                ? PPColor.mint
                : PPColor.accent,
            metrics: [
                WorkflowMetric(
                    value: "\(selectedIDs.count)",
                    label: "Selected",
                    symbol: "checkmark.circle",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: "\(verifiedCount)",
                    label: "Verified",
                    symbol: "checkmark.seal",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "\(attentionCount + failedCount)",
                    label: "Attention",
                    symbol: "exclamationmark.circle",
                    tint: attentionCount + failedCount == 0
                        ? PPColor.textSecondary
                        : PPColor.amber
                )
            ]
        )
    }

    private var headerTitle: String {
        switch phase {
        case .selecting: return "Prepare several"
        case .processing: return "Verifying one at a time"
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
                ? "\(verifiedCount) verified copies remain available"
                : "\(verifiedCount) verified · \(attentionCount + failedCount) need attention"
        }
    }

    private var selectionControls: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedIDs.count) selected")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textPrimary)
                Text("Choose up to 64 source documents")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
            Spacer()
            Button(
                selectedIDs.count == maximumSelectableCount
                    ? "Clear"
                    : "Select all"
            ) {
                withAnimation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 0.18)
                ) {
                    if selectedIDs.count == maximumSelectableCount {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = selectableRecordIDs
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.accent)
            .frame(minHeight: 44)
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
                        : "RESULT"
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
            HStack(spacing: PPSpacing.large) {
                resultMetric(
                    value: verifiedCount,
                    label: "Verified",
                    color: PPColor.mint
                )
                resultMetric(
                    value: attentionCount,
                    label: "Review",
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
            if dynamicTypeSize.isAccessibilitySize {
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

    private var documentRows: some View {
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

    private func batchDocumentRow(
        _ record: DocumentRecord
    ) -> some View {
        let item = items[record.id]
        let canOpenReview = item?.stage == .needsReview
            && item?.reviewPageIndex != nil
        let canOpenIssue = item?.issue != nil

        return Button {
            if phase == .selecting {
                toggle(record.id)
            } else if canOpenReview,
                      let pageIndex = item?.reviewPageIndex {
                batchTask?.cancel()
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    onOpenDocument(
                        DocumentRoute(
                            recordID: record.id,
                            pageIndex: pageIndex
                        )
                    )
                }
            } else if canOpenIssue {
                selectedIssueItem = item
            }
        } label: {
            HStack(spacing: PPSpacing.medium) {
                ZStack(alignment: .bottomTrailing) {
                    if let url = model.url(for: record.id) {
                        PDFPageThumbnailView(
                            url: url,
                            pageIndex: 0,
                            refreshToken: model.refreshToken(
                                for: record.id
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
                            symbol: record.profile.kind.symbol,
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
                    Text(
                        phase == .selecting
                            ? record.subtitle
                            : (item?.detail ?? "Waiting")
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)

                    if let issue = item?.issue {
                        Text(
                            "\(issue.phase.title.uppercased()) · \(issue.code)"
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
                    Text(item.stage.title.localizedUI)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(stageColor(item.stage))
                }
            }
            .frame(minHeight: 86)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(
            phase == .selecting
                || canOpenReview
                || canOpenIssue
        )
        .accessibilityLabel(accessibilityLabel(record, item: item))
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
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(stageColor(item.stage), in: Circle())
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
            if phase == .selecting {
                Button {
                    startBatch()
                } label: {
                    Label(
                        "Check & Create \(selectedIDs.count)",
                        systemImage: "checkmark.shield"
                    )
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(selectedIDs.isEmpty)
            } else if phase == .processing {
                Button {
                    wasStopped = true
                    batchTask?.cancel()
                } label: {
                    Label("Stop safely", systemImage: "stop.fill")
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
            } else {
                if !retryableIDs.isEmpty {
                    Button {
                        startBatch(recordIDs: retryableIDs)
                    } label: {
                        Label(
                            "Retry \(retryableIDs.count) Unfinished",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.amber)
                    )
                }

                if verifiedCount > 0 {
                    Button {
                        isSharing = true
                    } label: {
                        Label(
                            "Share \(verifiedCount) Verified PDF\(verifiedCount == 1 ? "" : "s")",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                } else if retryableIDs.isEmpty {
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

    private var eligibleRecords: [DocumentRecord] {
        model.workingDocuments
            .filter {
                !$0.profile.isLocked
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private var selectedRecords: [DocumentRecord] {
        eligibleRecords.filter { selectedIDs.contains($0.id) }
    }

    private var selectableRecordIDs: Set<UUID> {
        Set(
            eligibleRecords
                .prefix(maximumBatchCount)
                .map(\.id)
        )
    }

    private var maximumSelectableCount: Int {
        min(maximumBatchCount, eligibleRecords.count)
    }

    private var displayedRecords: [DocumentRecord] {
        guard phase != .selecting else { return eligibleRecords }
        guard phase == .finished,
              resultFilter == .attention
        else { return selectedRecords }
        return selectedRecords.filter { record in
            guard let item = items[record.id] else { return false }
            return !item.stage.isShareable
        }
    }

    private var shareURLs: [URL] {
        selectedRecords.compactMap { record in
            guard let outputID = items[record.id]?.outputRecordID,
                  items[record.id]?.stage.isShareable == true
            else { return nil }
            return model.url(for: outputID)
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
        if let run = model.recoverableBatchDeliveryRun() {
            selectedIDs = Set(run.sourceRecordIDs)
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
            resultFilter = .attention
            return
        }
        selectedIDs = selectableRecordIDs
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
                : .easeInOut(duration: 0.18)
        ) {
            if selectedIDs.contains(recordID) {
                selectedIDs.remove(recordID)
            } else {
                guard selectedIDs.count < maximumBatchCount else {
                    model.noticeMessage =
                        "A batch can include up to 64 PDFs"
                            .localizedUI
                    return
                }
                selectedIDs.insert(recordID)
            }
        }
    }

    private func startBatch(
        recordIDs requestedIDs: [UUID]? = nil
    ) {
        guard batchTask == nil, !selectedIDs.isEmpty else { return }
        let sourceIDs = requestedIDs ?? selectedRecords.map(\.id)
        guard !sourceIDs.isEmpty else { return }
        if requestedIDs == nil {
            batchRunID = UUID()
            batchStartedAt = Date()
        }
        phase = .processing
        wasStopped = false
        resultFilter = .all
        for sourceID in sourceIDs {
            items[sourceID] = PDFBatchDeliveryItem(
                sourceRecordID: sourceID,
                stage: .queued,
                detail: "Waiting for local preflight"
            )
        }
        batchTask = Task {
            await persistBatchRun()
            let results = await model.createSafeShareBatch(
                recordIDs: sourceIDs
            ) { update in
                withAnimation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 0.2)
                ) {
                    items[update.sourceRecordID] = update
                }
                scheduleBatchPersistence()
            }
            for result in results {
                items[result.sourceRecordID] = result
            }
            batchPersistenceTask?.cancel()
            await persistBatchRun()
            if Task.isCancelled {
                wasStopped = true
            }
            batchTask = nil
            phase = .finished
        }
    }

    private func resetBatch() {
        batchTask?.cancel()
        batchPersistenceTask?.cancel()
        selectedIssueItem = nil
        resultFilter = .all
        wasStopped = false
        phase = .selecting
        batchRunID = UUID()
        batchStartedAt = Date()
        selectedIDs = selectableRecordIDs
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
        Task {
            await model.clearBatchDeliveryRun()
        }
    }

    private func scheduleBatchPersistence() {
        batchPersistenceTask?.cancel()
        let runID = batchRunID
        let startedAt = batchStartedAt
        let sourceIDs = selectedRecords.map(\.id)
        let snapshot = sourceIDs.compactMap { items[$0] }
        batchPersistenceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(240))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await model.saveBatchDeliveryRun(
                id: runID,
                sourceRecordIDs: sourceIDs,
                items: snapshot,
                startedAt: startedAt
            )
        }
    }

    private func persistBatchRun() async {
        let sourceIDs = selectedRecords.map(\.id)
        await model.saveBatchDeliveryRun(
            id: batchRunID,
            sourceRecordIDs: sourceIDs,
            items: sourceIDs.compactMap { items[$0] },
            startedAt: batchStartedAt
        )
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
            return "\(record.displayName), \(selectedIDs.contains(record.id) ? "selected" : "not selected")"
        }
        return [
            record.displayName,
            item?.stage.title ?? "waiting",
            item?.detail ?? "",
            item?.issue?.recovery ?? ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

private struct BatchDeliveryIssueView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

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
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var issueHeader: some View {
        HStack(alignment: .top, spacing: PPSpacing.large) {
            if let record,
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
                    text: "\(issue.phase.title.uppercased()) · \(issue.code)"
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
            dismiss()
            onOpenSource()
        } label: {
            Label("Open Source", systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(PPQuietButtonStyle())
    }

    private var retryButton: some View {
        Button {
            dismiss()
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

    let recordID: UUID
    let onOpenDocument: (DocumentRoute) -> Void

    @State private var snapshot: PDFSourceLocationSnapshot?
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var exportTask: Task<Void, Never>?
    @State private var isConfirmingWriteback = false
    @State private var isWorking = false
    @State private var actionTask: Task<Void, Never>?
    @State private var sourceGeneration = 0
    @AppStorage(AppPreferences.metadataSyncEnabledKey)
    private var metadataSyncEnabled = false

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
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
            .overlay {
                if isLoading {
                    ProgressView("Checking Files source")
                }
            }
            .navigationTitle("Files & Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button((isWorking ? "Stop" : "Done").localizedUI) {
                        if isWorking {
                            actionTask?.cancel()
                            exportTask?.cancel()
                            actionTask = nil
                            exportTask = nil
                            isWorking = false
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .task {
                await reload()
            }
            .confirmationDialog(
                "Replace the original file?",
                isPresented: $isConfirmingWriteback,
                titleVisibility: .visible
            ) {
                Button("Replace Original") {
                    writeBack()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "PaperPath verified that the source has not changed since import. The private working copy remains in the library."
                )
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
                exportTask?.cancel()
                actionTask?.cancel()
                discardPreparedExport()
            }
            .interactiveDismissDisabled(isWorking)
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
                "Edits stay in PaperPath until you explicitly export or replace the original.",
                systemImage: "internaldrive"
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            WorkflowSectionHeader(
                eyebrow: "OPTIONAL METADATA",
                title: metadataSyncEnabled
                    ? metadataSyncTitle
                    : "iCloud metadata is off"
            )
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
                Spacer()
                if metadataSyncEnabled {
                    Button {
                        Task {
                            await model.synchronizeMetadata()
                        }
                    } label: {
                        Image(
                            systemName:
                                "arrow.triangle.2.circlepath"
                        )
                        .frame(width: 34, height: 34)
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

            if snapshot?.status == .current {
                Button(role: .destructive) {
                    isConfirmingWriteback = true
                } label: {
                    Label(
                        "Replace Original in Files",
                        systemImage: "arrow.down.doc"
                    )
                }
                .buttonStyle(PPQuietButtonStyle(tint: .red))
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
        let loadedSnapshot = await model.sourceLocation(
            recordID: recordID
        )
        guard !Task.isCancelled,
              generation == sourceGeneration
        else { return }
        snapshot = loadedSnapshot
        isLoading = false
    }

    private func prepareExport() {
        isWorking = true
        exportTask = Task {
            defer {
                isWorking = false
                exportTask = nil
            }
            guard !Task.isCancelled else { return }
            let preparedURL = await model.makeFilesExportCopy(
                recordID: recordID
            )
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

    private func writeBack() {
        isWorking = true
        actionTask = Task {
            _ = await model.writeBackToSource(recordID: recordID)
            guard !Task.isCancelled else {
                isWorking = false
                actionTask = nil
                return
            }
            await reload()
            isWorking = false
            actionTask = nil
        }
    }

    private func importChangedSource() {
        isWorking = true
        actionTask = Task {
            let imported = await model.importLatestSource(
                recordID: recordID
            )
            guard !Task.isCancelled else {
                isWorking = false
                actionTask = nil
                return
            }
            isWorking = false
            actionTask = nil
            guard let imported else { return }
            dismiss()
            onOpenDocument(
                DocumentRoute(recordID: imported.id)
            )
        }
    }
}
