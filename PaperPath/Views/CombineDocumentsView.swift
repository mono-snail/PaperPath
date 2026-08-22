import SwiftUI
import UniformTypeIdentifiers

struct CombineDocumentsView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("privacy.hideLibraryPreviews")
    private var hideLibraryPreviews = false

    let onCreated: (UUID) -> Void

    @State private var selectedIDs: [UUID] = []
    @State private var outputName = ""
    @State private var isAddingFiles = false
    @State private var operationTask: Task<Void, Never>?
    @State private var createdID: UUID?

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
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationTask != nil
                                ? "Stop"
                                : createdID == nil
                                    ? "Cancel"
                                    : "Done"
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
                where !record.profile.isLocked
                    && !selectedIDs.contains(record.id) {
                    selectedIDs.append(record.id)
                }
            }
        }
        .interactiveDismissDisabled(operationTask != nil)
        .onDisappear {
            operationTask?.cancel()
        }
        .sensoryFeedback(.selection, trigger: selectedIDs.count)
        .sensoryFeedback(.success, trigger: createdID)
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: PPSpacing.large) {
            taskHeader
            sourceActions

            if horizontalSizeClass == .regular,
               !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: PPSpacing.large) {
                    VStack(alignment: .leading, spacing: PPSpacing.medium) {
                        if !selectedIDs.isEmpty {
                            selectedOrder
                            nameField
                        } else {
                            compactMergeHint
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    availableDocuments
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                if !selectedIDs.isEmpty {
                    selectedOrder
                    nameField
                }
                availableDocuments
            }
        }
    }

    private var taskHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "MERGE WORKFLOW",
            title: "Merge PDFs",
            detail: selectedIDs.isEmpty
                ? "Choose PDFs, set their order, then create one private copy."
                : "Review order and name before creating the combined copy.",
            symbol: "square.stack.3d.up",
            tint: PPColor.mint,
            metrics: [
                WorkflowMetric(
                    value: "\(selectedIDs.count)",
                    label: "Selected",
                    symbol: "checkmark.circle",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "\(selectedRecords.reduce(0) { $0 + $1.profile.pageCount })",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: ByteCountFormatter.string(
                        fromByteCount: selectedRecords.reduce(0) {
                            $0 + $1.profile.byteCount
                        },
                        countStyle: .file
                    ),
                    label: "Input",
                    symbol: "internaldrive",
                    tint: PPColor.cyan
                )
            ]
        )
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
            .disabled(model.isImporting || operationTask != nil)
        }
    }

    private var selectedOrder: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            HStack {
                SectionEyebrow(text: "MERGE ORDER")
                Spacer()
                Text("\(selectedIDs.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.mint)
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
        HStack(spacing: PPSpacing.small) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(PPColor.mint)
                .clipShape(Circle())

            sourcePreview(record)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.body.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(record.subtitle)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                orderButton(
                    symbol: "arrow.up",
                    label: "Move earlier",
                    disabled: index == 0
                ) {
                    move(from: index, to: index - 1)
                }
                orderButton(
                    symbol: "arrow.down",
                    label: "Move later",
                    disabled: index == selectedIDs.count - 1
                ) {
                    move(from: index, to: index + 1)
                }
                orderButton(
                    symbol: "xmark",
                    label: "Remove",
                    tint: PPColor.amber
                ) {
                    selectedIDs.remove(at: index)
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
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
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || operationTask != nil)
        .opacity(disabled ? 0.28 : 1)
        .accessibilityLabel(label.localizedUI)
        .help(label.localizedUI)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "NEW COPY NAME")
            TextField("Combined document".localizedUI, text: $outputName)
                .textInputAutocapitalization(.words)
                .font(.body)
                .padding(PPSpacing.medium)
                .background(PPColor.surfaceMuted)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PPRadius.control,
                        style: .continuous
                    )
                )
        }
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
            }

            if availableRecords.isEmpty {
                VStack(spacing: PPSpacing.medium) {
                    Image(systemName: "doc.badge.plus")
                        .font(.title2)
                        .foregroundStyle(PPColor.accent)
                    Text(
                        selectedIDs.isEmpty
                            ? "Add PDFs from Files".localizedUI
                            : "All available PDFs are selected".localizedUI
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
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

        return Button {
            selectedIDs.append(record.id)
        } label: {
            HStack(spacing: PPSpacing.medium) {
                Image(
                    systemName: supported
                        ? "plus.circle"
                        : "lock.circle"
                )
                    .font(.title3)
                    .foregroundStyle(
                        supported ? PPColor.accent : PPColor.textSecondary
                    )
                    .frame(width: 28)

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

                Spacer()
            }
            .padding(.vertical, PPSpacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!supported || operationTask != nil)
        .opacity(supported ? 1 : 0.48)
        .accessibilityLabel(
            AppLocalization.format("Add %@", record.displayName)
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
                        value: "\(selectedIDs.count)",
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

            Button {
                dismiss()
                onCreated(record.id)
            } label: {
                HStack(spacing: PPSpacing.medium) {
                    sourcePreview(record)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.displayName)
                            .font(.body.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(2)
                        Text(record.subtitle)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                            .monospacedDigit()
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PPColor.mint)
                }
                .padding(.vertical, PPSpacing.medium)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: PPSpacing.small) {
            if operationTask != nil {
                HStack(spacing: PPSpacing.medium) {
                    ProgressView()
                    Text("Merging PDFs on this device".localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                    Spacer()
                }
                .frame(minHeight: 52)
            } else if let createdRecord {
                Button {
                    dismiss()
                    onCreated(createdRecord.id)
                } label: {
                    Label("Open Result", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(PPPrimaryButtonStyle())
            } else {
                Button {
                    operationTask = Task {
                        let created = await model.combineDocuments(
                            recordIDs: selectedIDs,
                            name: outputName
                        )
                        guard !Task.isCancelled else {
                            operationTask = nil
                            return
                        }
                        createdID = created?.id
                        operationTask = nil
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
                .disabled(selectedIDs.count < 2 || model.isImporting)
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

    private var availableRecords: [DocumentRecord] {
        model.workingDocuments.filter {
            $0.workflowStatus != .archived
                && !selectedIDs.contains($0.id)
        }
    }

    private var createdRecord: DocumentRecord? {
        createdID.flatMap { model.record(id: $0) }
    }

    private func move(from source: Int, to destination: Int) {
        guard selectedIDs.indices.contains(source),
              selectedIDs.indices.contains(destination),
              source != destination
        else { return }
        let id = selectedIDs.remove(at: source)
        selectedIDs.insert(id, at: destination)
    }
}
