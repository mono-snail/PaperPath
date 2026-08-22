import SwiftUI
import UniformTypeIdentifiers

struct BatchBatesNumberingView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    @State private var orderedRecordIDs: [UUID]
    @State private var searchText = ""
    @State private var position = PDFPageNumberPosition.bottomRight
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var digitCount = 6
    @State private var startNumberText = "1"
    @State private var operationTask: Task<Void, Never>?
    @State private var successFeedback = 0
    @State private var errorFeedback = 0
    @State private var isPresentingReceiptHistory = false
    @State private var issuedReceipt:
        PDFSignedBatesBatchReceipt?

    init(initialRecordIDs: [UUID] = []) {
        _orderedRecordIDs = State(initialValue: initialRecordIDs)
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
                        batchHeader
                        sequenceSection
                            .disabled(operationTask != nil)
                        documentSection
                            .disabled(operationTask != nil)
                    }
                    .frame(maxWidth: 860)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 108)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Bates Several PDFs")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(
                    displayMode: .always
                ),
                prompt: "Filter PDFs"
            )
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
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            selectAllVisible()
                        } label: {
                            Label(
                                "Select All",
                                systemImage: "checkmark.circle"
                            )
                        }
                        .disabled(
                            filteredEligibleRecords.allSatisfy {
                                orderedRecordIDs.contains($0.id)
                            }
                        )

                        Button {
                            orderedRecordIDs.removeAll()
                        } label: {
                            Label(
                                "Clear Selection",
                                systemImage: "xmark.circle"
                            )
                        }
                        .disabled(orderedRecordIDs.isEmpty)

                        if !model.batesBatchReceipts.isEmpty {
                            Divider()
                            Button {
                                isPresentingReceiptHistory = true
                            } label: {
                                Label(
                                    "Bates Receipts",
                                    systemImage: "checkmark.seal"
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(operationTask != nil)
                    .accessibilityLabel("Batch selection options")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
        }
        .interactiveDismissDisabled(operationTask != nil)
        .sheet(isPresented: $isPresentingReceiptHistory) {
            BatesBatchReceiptHistoryView()
        }
        .sheet(item: $issuedReceipt, onDismiss: {
            dismiss()
        }) { receipt in
            BatesBatchReceiptView(receiptID: receipt.id)
        }
        .sensoryFeedback(.success, trigger: successFeedback)
        .sensoryFeedback(.error, trigger: errorFeedback)
        .sensoryFeedback(
            .selection,
            trigger: orderedRecordIDs
        )
        .onChange(of: prefix) { _, value in
            if value.count > 64 {
                prefix = String(value.prefix(64))
            }
        }
        .onChange(of: suffix) { _, value in
            if value.count > 64 {
                suffix = String(value.prefix(64))
            }
        }
        .onChange(of: startNumberText) { _, value in
            let digits = value.filter {
                "0123456789".contains($0)
            }
            let bounded = String(digits.prefix(15))
            if bounded != value {
                startNumberText = bounded
            }
        }
        .onChange(of: eligibleRecords.map(\.id), initial: true) {
            _,
            eligibleIDs in
            guard operationTask == nil else { return }
            let eligibleSet = Set(eligibleIDs)
            orderedRecordIDs.removeAll {
                !eligibleSet.contains($0)
            }
        }
        .onDisappear {
            operationTask?.cancel()
            operationTask = nil
        }
    }

    private var batchHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "CONTINUOUS BATES",
            title: operationTask == nil
                ? "One sequence across PDFs"
                : model.batesBatchProgress?.stage.title
                    ?? "Preparing numbered copies",
            detail: operationTask == nil
                ? "Order private copies, preview every range, then commit them together."
                : model.batesBatchProgress?.currentDocumentName
                    ?? "Checking selected PDFs",
            symbol: "square.stack.3d.up.fill",
            tint: operationTask == nil
                ? PPColor.amber
                : PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(orderedRecordIDs.count)",
                    label: "PDFs",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: "\(selectedPageCount)",
                    label: "Pages",
                    symbol: "book.pages",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: batchRangeSummary,
                    label: "Sequence",
                    symbol: "number",
                    tint: PPColor.amber
                )
            ]
        )
    }

    private var sequenceSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "SEQUENCE")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    affixField(
                        title: "Prefix",
                        placeholder: "CASE-",
                        text: $prefix
                    )
                    affixField(
                        title: "Suffix",
                        placeholder: "-A",
                        text: $suffix
                    )
                }
                VStack(spacing: PPSpacing.small) {
                    affixField(
                        title: "Prefix",
                        placeholder: "CASE-",
                        text: $prefix
                    )
                    affixField(
                        title: "Suffix",
                        placeholder: "-A",
                        text: $suffix
                    )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.large) {
                    startNumberField
                    digitCountControl
                }
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.medium
                ) {
                    startNumberField
                    digitCountControl
                }
            }

            HStack(spacing: PPSpacing.medium) {
                Label("Position", systemImage: position.symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Position", selection: $position) {
                    ForEach(PDFPageNumberPosition.allCases) { option in
                        Label(
                            option.title.localizedUI,
                            systemImage: option.symbol
                        )
                        .tag(option)
                    }
                }
                .pickerStyle(.menu)
            }

            if let validationMessage {
                Label(
                    validationMessage.localizedUI,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
                .fixedSize(horizontal: false, vertical: true)
            } else if let plan {
                Label(
                    AppLocalization.format(
                        "%lld pages run from %@ to %@",
                        plan.totalPageCount,
                        plan.firstIdentifier,
                        plan.lastIdentifier
                    ),
                    systemImage: "checkmark.shield"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.mint)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, PPSpacing.small)
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

    private var startNumberField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Starting number".localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
            TextField("1", text: $startNumberText)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
        }
        .frame(maxWidth: 320)
    }

    private var digitCountControl: some View {
        Stepper(
            AppLocalization.format(
                "Number of digits %lld",
                digitCount
            ),
            value: $digitCount,
            in: 3...15
        )
        .font(.subheadline.monospacedDigit())
        .frame(maxWidth: 320)
    }

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                SectionEyebrow(text: "DOCUMENT ORDER")
                Text("\(orderedRecordIDs.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.amber)
                Spacer()
                Text("Top to bottom".localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
            }

            if displayedRecords.isEmpty {
                ContentUnavailableView(
                    "No eligible PDFs",
                    systemImage: "doc.questionmark",
                    description: Text(
                        "Unlocked working copies appear here."
                    )
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, PPSpacing.large)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedRecords) { record in
                        documentRow(record)
                        Rectangle()
                            .fill(PPColor.border.opacity(0.52))
                            .frame(height: 0.6)
                            .padding(.leading, 50)
                    }
                }
            }
        }
    }

    private func documentRow(
        _ record: DocumentRecord
    ) -> some View {
        let selectedIndex = orderedRecordIDs.firstIndex(
            of: record.id
        )
        let planItem = plan?.items.first {
            $0.recordID == record.id
        }

        return HStack(spacing: PPSpacing.small) {
            Button {
                toggle(record.id)
            } label: {
                Image(
                    systemName: selectedIndex == nil
                        ? "circle"
                        : "checkmark.circle.fill"
                )
                .font(.title3)
                .foregroundStyle(
                    selectedIndex == nil
                        ? PPColor.textSecondary
                        : PPColor.amber
                )
                .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(operationTask != nil)
            .accessibilityLabel(
                AppLocalization.format(
                    selectedIndex == nil
                        ? "Select %@"
                        : "Deselect %@",
                    record.displayName
                )
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let selectedIndex {
                        Text("\(selectedIndex + 1)")
                            .font(
                                .caption2.monospacedDigit().weight(.black)
                            )
                            .foregroundStyle(PPColor.surface)
                            .frame(width: 22, height: 22)
                            .background(PPColor.amber, in: Circle())
                    }
                    Text(record.displayName)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                }

                Text(
                    planItem.map {
                        AppLocalization.format(
                            "%lld pages | %@ to %@",
                            $0.pageCount,
                            plan?.identifier(for: $0.startNumber) ?? "",
                            plan?.identifier(for: $0.endNumber) ?? ""
                        )
                    } ?? record.subtitle
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(2)
            }

            Spacer(minLength: PPSpacing.small)

            if let selectedIndex {
                HStack(spacing: 0) {
                    orderButton(
                        symbol: "arrow.up",
                        label: "Move earlier",
                        disabled: selectedIndex == 0
                    ) {
                        move(record.id, offset: -1)
                    }
                    orderButton(
                        symbol: "arrow.down",
                        label: "Move later",
                        disabled:
                            selectedIndex
                                == orderedRecordIDs.count - 1
                    ) {
                        move(record.id, offset: 1)
                    }
                }
            }
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private func orderButton(
        symbol: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 38, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            disabled ? PPColor.border : PPColor.textSecondary
        )
        .disabled(disabled || operationTask != nil)
        .accessibilityLabel(label)
        .help(label.localizedUI)
    }

    private var actionFooter: some View {
        VStack(spacing: PPSpacing.small) {
            if let progress = model.batesBatchProgress,
               operationTask != nil {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(progress.stage.title.localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Spacer()
                        Text(
                            "\(progress.completedDocumentCount)/\(progress.totalDocumentCount)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                    }
                    ProgressView(value: progress.fractionCompleted)
                        .tint(PPColor.cyan)
                }
            }

            actionButton
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let operationTask {
            Button {
                operationTask.cancel()
            } label: {
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "stop.fill")
                    Text("Stop before commit".localizedUI)
                    Spacer()
                }
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
        } else {
            Button {
                apply()
            } label: {
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "number.square.fill")
                    Text(
                        AppLocalization.format(
                            "Bates number %lld PDFs",
                            orderedRecordIDs.count
                        )
                    )
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(plan == nil)
        }
    }

    private func affixField(
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
    }

    private var eligibleRecords: [DocumentRecord] {
        model.workingDocuments.filter {
            !$0.profile.isLocked
                && $0.profile.pageCount > 0
                && (
                    !model.isProcessing($0.id)
                        || (
                            operationTask != nil
                                && orderedRecordIDs.contains($0.id)
                        )
                )
        }
    }

    private var filteredEligibleRecords: [DocumentRecord] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return eligibleRecords }
        return eligibleRecords.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var displayedRecords: [DocumentRecord] {
        let filteredIDs = Set(filteredEligibleRecords.map(\.id))
        let ordered = selectedRecords.filter {
            filteredIDs.contains($0.id)
        }
        let unselected = filteredEligibleRecords.filter {
            !orderedRecordIDs.contains($0.id)
        }
        return ordered + unselected
    }

    private var selectedRecords: [DocumentRecord] {
        orderedRecordIDs.compactMap {
            model.record(id: $0)
        }
    }

    private var selectedPageCount: Int {
        selectedRecords.reduce(0) {
            $0 + $1.profile.pageCount
        }
    }

    private var startNumber: Int64? {
        Int64(startNumberText)
    }

    private var plan: PDFBatesBatchPlan? {
        guard let startNumber else { return nil }
        return try? model.batesBatchPlan(
            recordIDs: orderedRecordIDs,
            startNumber: startNumber,
            digitCount: digitCount,
            prefix: prefix,
            suffix: suffix,
            position: position
        )
    }

    private var validationMessage: String? {
        guard selectedRecords.count == orderedRecordIDs.count else {
            return "A selected working copy is unavailable."
        }
        guard orderedRecordIDs.count >= 2 else {
            return "Choose at least two PDFs for continuous Bates numbering."
        }
        guard orderedRecordIDs.count
                <= PDFBatesBatchPlan.maximumDocumentCount
        else {
            return "Bates number up to 64 PDFs at a time."
        }
        guard selectedPageCount
                <= PDFBatesBatchPlan.maximumPageCount
        else {
            return "Bates number up to 10,000 pages in one batch."
        }
        guard prefix.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).count <= 24,
              suffix.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).count <= 24
        else {
            return "Use 24 characters or fewer for prefix and suffix."
        }
        guard !prefix.contains("#"),
              !suffix.contains("#"),
              prefix.rangeOfCharacter(
                  from: .controlCharacters
              ) == nil,
              suffix.rangeOfCharacter(
                  from: .controlCharacters
              ) == nil
        else {
            return "Prefix and suffix cannot contain # or line breaks."
        }
        guard let startNumber, startNumber >= 1 else {
            return "Enter a starting number of 1 or greater."
        }
        let maximum = PDFBatesNumberingPayload.maximumNumber(
            digitCount: digitCount
        )
        guard selectedPageCount > 0,
              startNumber <= maximum - Int64(selectedPageCount - 1)
        else {
            return "Increase the digit count for this sequence."
        }
        return nil
    }

    private var batchRangeSummary: String {
        guard let plan else { return "-" }
        return "\(plan.firstIdentifier)-\(plan.lastIdentifier)"
    }

    private func toggle(_ recordID: UUID) {
        if let index = orderedRecordIDs.firstIndex(of: recordID) {
            orderedRecordIDs.remove(at: index)
        } else {
            orderedRecordIDs.append(recordID)
        }
    }

    private func move(_ recordID: UUID, offset: Int) {
        guard let sourceIndex = orderedRecordIDs.firstIndex(
            of: recordID
        ) else { return }
        let destinationIndex = sourceIndex + offset
        guard orderedRecordIDs.indices.contains(destinationIndex)
        else { return }
        orderedRecordIDs.swapAt(sourceIndex, destinationIndex)
    }

    private func selectAllVisible() {
        for record in filteredEligibleRecords
        where !orderedRecordIDs.contains(record.id) {
            orderedRecordIDs.append(record.id)
        }
    }

    private func apply() {
        guard let plan else {
            errorFeedback += 1
            return
        }
        let previousReceiptID = model.batesBatchReceipts.first?.id
        operationTask = Task {
            let succeeded = await model.applyBatesNumbersBatch(plan)
            operationTask = nil
            guard succeeded else {
                if !Task.isCancelled {
                    errorFeedback += 1
                }
                return
            }
            successFeedback += 1
            if let latest = model.batesBatchReceipts.first,
               latest.id != previousReceiptID {
                issuedReceipt = latest
            } else {
                dismiss()
            }
        }
    }
}

struct BatesBatchReceiptHistoryView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedReceipt:
        PDFSignedBatesBatchReceipt?
    @State private var receiptPendingDeletion:
        PDFSignedBatesBatchReceipt?
    @State private var isImportingReceipt = false
    @State private var isInspectingReceipt = false
    @State private var inspectionTask: Task<Void, Never>?
    @State private var importedInspection:
        PDFBatesBatchReceiptInspection?
    @State private var isImportingMatchReport = false
    @State private var isInspectingMatchReport = false
    @State private var matchInspectionTask: Task<Void, Never>?
    @State private var importedMatchInspection:
        PDFBatesMatchReportInspection?

    var onOpenDocument: ((UUID) -> Void)?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if filteredReceipts.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty
                            ? "No Bates receipts"
                            : "No matching receipts",
                        systemImage: searchText.isEmpty
                            ? "checkmark.seal"
                            : "magnifyingglass",
                        description: Text(
                            searchText.isEmpty
                                ? "A signed receipt is saved after a multi-PDF Bates batch."
                                : "Try a file name, sequence, or signer Key ID."
                        )
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredReceipts) { receipt in
                                receiptRow(receipt)
                                Rectangle()
                                    .fill(PPColor.border.opacity(0.58))
                                    .frame(height: 0.6)
                                    .padding(.leading, 50)
                            }
                        }
                        .frame(maxWidth: 820)
                        .padding(.horizontal, PPSpacing.regular)
                        .padding(.vertical, PPSpacing.small)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Bates Receipts")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                prompt: "Search receipts"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isImportingReceipt = true
                        } label: {
                            Label(
                                "Verify Bates Receipt",
                                systemImage: "checkmark.seal"
                            )
                        }
                        Button {
                            isImportingMatchReport = true
                        } label: {
                            Label(
                                "Verify Match Report",
                                systemImage:
                                    "doc.text.magnifyingglass"
                            )
                        }
                    } label: {
                        if isInspectingReceipt
                            || isInspectingMatchReport {
                            ProgressView()
                        } else {
                            Image(
                                systemName:
                                    "doc.badge.magnifyingglass"
                            )
                        }
                    }
                    .disabled(
                        isInspectingReceipt
                            || isInspectingMatchReport
                    )
                    .accessibilityLabel(
                        isInspectingReceipt || isInspectingMatchReport
                            ? "Verifying PaperPath JSON"
                            : "Verify PaperPath JSON from Files"
                    )
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingReceipt,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first
            else {
                if case .failure(let error) = result {
                    model.present(error)
                }
                return
            }
            inspectExternalReceipt(url)
        }
        .fileImporter(
            isPresented: $isImportingMatchReport,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first
            else {
                if case .failure(let error) = result {
                    model.present(error)
                }
                return
            }
            inspectExternalMatchReport(url)
        }
        .sheet(item: $selectedReceipt) { receipt in
            BatesBatchReceiptView(
                receiptID: receipt.id,
                onOpenDocument: onOpenDocument
            )
        }
        .sheet(item: $importedInspection) { inspection in
            ExternalBatesReceiptView(inspection: inspection)
        }
        .sheet(item: $importedMatchInspection) { inspection in
            BatesMatchReportInspectionView(
                inspection: inspection
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isInspectingReceipt || isInspectingMatchReport {
                externalVerificationProgress
            }
        }
        .confirmationDialog(
            "Delete this local Bates receipt?",
            isPresented: Binding(
                get: { receiptPendingDeletion != nil },
                set: {
                    if !$0 {
                        receiptPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Receipt", role: .destructive) {
                guard let receipt = receiptPendingDeletion else {
                    return
                }
                receiptPendingDeletion = nil
                Task {
                    _ = await model.deleteBatesBatchReceipt(
                        receiptID: receipt.id
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                receiptPendingDeletion = nil
            }
        } message: {
            Text(
                "The PDFs and their Bates numbers are not changed."
            )
        }
        .onDisappear {
            inspectionTask?.cancel()
            inspectionTask = nil
            matchInspectionTask?.cancel()
            matchInspectionTask = nil
        }
    }

    private var filteredReceipts:
        [PDFSignedBatesBatchReceipt] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else {
            return model.batesBatchReceipts
        }
        return model.batesBatchReceipts.filter { receipt in
            receipt.signature.keyID
                .localizedCaseInsensitiveContains(query)
                || receipt.removal?.signature.keyID
                    .localizedCaseInsensitiveContains(query) == true
                || receipt.payload.firstIdentifier
                    .localizedCaseInsensitiveContains(query)
                || receipt.payload.lastIdentifier
                    .localizedCaseInsensitiveContains(query)
                || receipt.payload.entries.contains {
                    $0.displayName
                        .localizedCaseInsensitiveContains(query)
                }
        }
    }

    private func receiptRow(
        _ receipt: PDFSignedBatesBatchReceipt
    ) -> some View {
        Button {
            selectedReceipt = receipt
        } label: {
            HStack(spacing: PPSpacing.small) {
                Image(
                    systemName: receipt.removal == nil
                        ? "checkmark.seal.fill"
                        : "arrow.uturn.backward.circle.fill"
                )
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        receipt.removal == nil
                            ? PPColor.mint
                            : PPColor.cyan
                    )
                    .frame(width: 38)

                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "\(receipt.payload.firstIdentifier) - \(receipt.payload.lastIdentifier)"
                    )
                    .font(.subheadline.monospaced().weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)

                    Text(
                        AppLocalization.format(
                            "%lld PDFs | %lld pages | Key %@",
                            receipt.payload.documentCount,
                            receipt.payload.totalPageCount,
                            receipt.shortKeyID
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)

                    Text(
                        receipt.removal.map {
                            AppLocalization.format(
                                "Removed %@",
                                $0.payload.createdAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                        } ?? receipt.payload.createdAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                }

                Spacer(minLength: PPSpacing.small)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PPColor.mint)
            }
            .frame(minHeight: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                receiptPendingDeletion = receipt
            } label: {
                Label(
                    "Delete Receipt",
                    systemImage: "trash"
                )
            }
        }
        .accessibilityLabel(
            AppLocalization.format(
                "Bates receipt %@ to %@, %lld PDFs",
                receipt.payload.firstIdentifier,
                receipt.payload.lastIdentifier,
                receipt.payload.documentCount
            )
        )
        .accessibilityValue(
            (
                receipt.removal == nil
                    ? "Bates applied"
                    : "Bates removed"
            ).localizedUI
        )
    }

    private var externalVerificationProgress: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(
                    isInspectingMatchReport
                        ? "Reading signed match report".localizedUI
                        : (
                            model.batesReceiptVerificationProgress?
                                .currentDocumentName
                                ?? "Reading signed receipt".localizedUI
                        )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
                Spacer()
                if let progress =
                    model.batesReceiptVerificationProgress {
                    Text(
                        "\(progress.completedDocumentCount)/\(progress.totalDocumentCount)"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                }
            }
            ProgressView(
                value: isInspectingMatchReport
                    ? nil
                    : (
                        model.batesReceiptVerificationProgress?
                            .fractionCompleted ?? 0
                    )
            )
            .tint(PPColor.cyan)
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private func inspectExternalReceipt(_ url: URL) {
        guard !isInspectingMatchReport else { return }
        inspectionTask?.cancel()
        isInspectingReceipt = true
        inspectionTask = Task {
            let inspection = await model
                .inspectExternalBatesBatchReceipt(at: url)
            guard !Task.isCancelled else { return }
            isInspectingReceipt = false
            inspectionTask = nil
            importedInspection = inspection
        }
    }

    private func inspectExternalMatchReport(_ url: URL) {
        guard !isInspectingReceipt else { return }
        matchInspectionTask?.cancel()
        isInspectingMatchReport = true
        matchInspectionTask = Task {
            let inspection = await model
                .inspectExternalBatesMatchReport(at: url)
            guard !Task.isCancelled else { return }
            isInspectingMatchReport = false
            matchInspectionTask = nil
            importedMatchInspection = inspection
        }
    }
}

struct ExternalBatesReceiptView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let inspection: PDFBatesBatchReceiptInspection

    @State private var isSaving = false
    @State private var saveFeedback = 0
    @State private var isSelectingPDFs = false
    @State private var matchTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var matchReport: PDFBatesExternalMatchReport?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.large
                    ) {
                        verificationHeader
                        sourceSection
                        documentSection
                    }
                    .frame(maxWidth: 860)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 96)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Verify Bates Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        matchTask == nil && saveTask == nil
                            ? "Close"
                            : "Stop"
                    ) {
                        if let matchTask {
                            matchTask.cancel()
                        } else if let saveTask {
                            saveTask.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
        }
        .interactiveDismissDisabled(
            isSaving || matchTask != nil
        )
        .sensoryFeedback(.success, trigger: saveFeedback)
        .fileImporter(
            isPresented: $isSelectingPDFs,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result,
                  !urls.isEmpty
            else {
                if case .failure(let error) = result {
                    model.present(error)
                }
                return
            }
            match(urls)
        }
        .sheet(item: $matchReport) { report in
            ExternalBatesFileMatchView(
                receipt: inspection.receipt,
                report: report
            ) {
                Task { @MainActor in
                    try? await Task.sleep(
                        for: .milliseconds(180)
                    )
                    isSelectingPDFs = true
                }
            }
        }
        .onDisappear {
            matchTask?.cancel()
            matchTask = nil
            saveTask?.cancel()
            saveTask = nil
        }
    }

    private var verificationHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "EXTERNAL BATES RECEIPT",
            title: verificationTitle,
            detail: inspection.report.detail,
            symbol: verificationSymbol,
            tint: verificationColor,
            metrics: [
                WorkflowMetric(
                    value:
                        "\(inspection.receipt.payload.documentCount)",
                    label: "PDFs",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value:
                        "\(inspection.receipt.payload.totalPageCount)",
                    label: "Pages",
                    symbol: "book.pages",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value:
                        "\(inspection.report.currentCount)/\(inspection.receipt.payload.documentCount)",
                    label: "Current",
                    symbol: "checkmark.circle",
                    tint: inspection.report.isCurrent
                        ? PPColor.mint
                        : PPColor.amber
                )
            ]
        )
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "VERIFICATION")
            externalFact(
                "Source file",
                value: inspection.sourceFileName,
                symbol: "doc"
            )
            externalFact(
                "Signature",
                value: inspection.report.signatureStatus.title.localizedUI,
                symbol: inspection.report.signatureStatus.symbol
            )
            externalFact(
                "Signer",
                value: signerTitle,
                symbol: inspection.report.trustStatus.symbol
            )
            externalFact(
                "Key ID",
                value: inspection.receipt.signature.keyID,
                symbol: "key"
            )
            Label(
                "This proves the manifest was signed by the shown key. It is not a certificate signature, legal identity, or trusted timestamp.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, PPSpacing.small)
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

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(text: "DOCUMENT REFERENCES")
                .padding(.bottom, PPSpacing.small)
            ForEach(
                Array(inspection.report.items.enumerated()),
                id: \.element.id
            ) { offset, item in
                HStack(spacing: PPSpacing.small) {
                    Text("\(offset + 1)")
                        .font(
                            .caption2.monospacedDigit().weight(.black)
                        )
                        .foregroundStyle(PPColor.surface)
                        .frame(width: 24, height: 24)
                        .background(
                            statusColor(item.status),
                            in: Circle()
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.entry.displayName)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Text(
                            "\(item.entry.startIdentifier) - \(item.entry.endIdentifier)"
                        )
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(PPColor.amber)
                        .lineLimit(1)
                        Text(item.detail.localizedUI)
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: PPSpacing.small)
                    Label(
                        item.status.title.localizedUI,
                        systemImage: item.status.symbol
                    )
                    .labelStyle(.iconOnly)
                    .foregroundStyle(statusColor(item.status))
                }
                .frame(minHeight: 70)
                .accessibilityElement(children: .combine)
                Rectangle()
                    .fill(PPColor.border.opacity(0.52))
                    .frame(height: 0.6)
                    .padding(.leading, 42)
            }
        }
    }

    private var actionFooter: some View {
        VStack(spacing: PPSpacing.small) {
            if let progress = model.batesExternalMatchProgress,
               progress.receiptID == inspection.receipt.id,
               matchTask != nil {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(progress.currentFileName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(
                            "\(progress.completedFileCount)/\(progress.totalFileCount)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                    }
                    ProgressView(value: progress.fractionCompleted)
                        .tint(PPColor.cyan)
                }
            }

            HStack(spacing: PPSpacing.small) {
                Button {
                    if let matchTask {
                        matchTask.cancel()
                    } else {
                        isSelectingPDFs = true
                    }
                } label: {
                    Label(
                        matchTask == nil
                            ? "Match PDF Files"
                            : "Stop Matching",
                        systemImage:
                            matchTask == nil
                                ? "doc.text.magnifyingglass"
                                : "stop.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(
                    inspection.report.signatureStatus != .verified
                )

                Button {
                    keepReceipt()
                } label: {
                    Label(
                        isAlreadySaved
                            ? "Saved"
                            : (
                                isSaving
                                    ? "Saving"
                                    : "Keep"
                            ),
                        systemImage: isAlreadySaved
                            ? "checkmark.circle.fill"
                            : "tray.and.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.cyan)
                )
                .disabled(
                    isAlreadySaved
                        || isSaving
                        || matchTask != nil
                        || inspection.report.signatureStatus
                            != .verified
                )
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private var isAlreadySaved: Bool {
        model.batesBatchReceipts.contains {
            $0 == inspection.receipt
        }
    }

    private var verificationTitle: String {
        guard inspection.report.signatureStatus == .verified else {
            return "Invalid signed receipt"
        }
        switch inspection.report.trustStatus {
        case .thisDevice:
            return "Signed by this device"
        case .trusted:
            return "Signed by a trusted source"
        case .unknown:
            return "Valid signature, unknown source"
        case .invalid:
            return "Invalid signed receipt"
        case .unsupported:
            return "Unsupported signed receipt"
        }
    }

    private var verificationSymbol: String {
        inspection.report.signatureStatus == .verified
            ? inspection.report.trustStatus.symbol
            : "xmark.seal.fill"
    }

    private var verificationColor: Color {
        guard inspection.report.signatureStatus == .verified else {
            return PPColor.rose
        }
        switch inspection.report.trustStatus {
        case .thisDevice, .trusted: return PPColor.mint
        case .unknown: return PPColor.amber
        case .invalid, .unsupported: return PPColor.rose
        }
    }

    private var signerTitle: String {
        if let name = inspection.report.trustedSignerName {
            return name
        }
        return inspection.report.trustStatus.title.localizedUI
    }

    private func externalFact(
        _ title: String,
        value: String,
        symbol: String
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Image(systemName: symbol)
                .foregroundStyle(PPColor.cyan)
                .frame(width: 24)
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
            Spacer(minLength: PPSpacing.small)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(PPColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(minHeight: 34)
    }

    private func statusColor(
        _ status: PDFBatesBatchEntryStatus
    ) -> Color {
        switch status {
        case .current: return PPColor.mint
        case .removed: return PPColor.cyan
        case .changed, .inTrash: return PPColor.amber
        case .missing, .untrusted: return PPColor.rose
        }
    }

    private func keepReceipt() {
        guard !isAlreadySaved,
              inspection.report.signatureStatus == .verified
        else { return }
        isSaving = true
        saveTask = Task {
            let saved = await model.retainExternalBatesBatchReceipt(
                inspection.receipt
            )
            isSaving = false
            saveTask = nil
            guard saved else { return }
            saveFeedback += 1
            dismiss()
        }
    }

    private func match(_ urls: [URL]) {
        matchTask?.cancel()
        matchTask = Task {
            let report = await model.matchExternalBatesPDFs(
                receipt: inspection.receipt,
                candidateURLs: urls
            )
            let wasCancelled = Task.isCancelled
            matchTask = nil
            guard !wasCancelled else { return }
            matchReport = report
        }
    }
}

struct ExternalBatesFileMatchView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let receipt: PDFSignedBatesBatchReceipt
    let report: PDFBatesExternalMatchReport
    let onChooseAgain: () -> Void

    @State private var exportTask: Task<Void, Never>?
    @State private var shareURL: URL?
    @State private var isSharing = false
    @State private var isConfirmingExport = false
    @State private var exportFeedback = 0

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.large
                    ) {
                        resultHeader
                        explanation
                        matchSection
                        if !report.unrecognizedCandidates.isEmpty {
                            unrecognizedSection
                        }
                    }
                    .frame(maxWidth: 860)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 88)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("PDF Match Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(exportTask != nil)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
        }
        .interactiveDismissDisabled(exportTask != nil)
        .sheet(isPresented: $isSharing, onDismiss: removeShareFile) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .sensoryFeedback(.success, trigger: exportFeedback)
        .confirmationDialog(
            "Share signed match report?",
            isPresented: $isConfirmingExport,
            titleVisibility: .visible
        ) {
            Button("Create and Share") {
                exportReport()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The JSON includes receipt document names, selected PDF file names, byte sizes, and SHA-256 fingerprints. PDF bytes are not included."
            )
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            removeShareFile()
        }
    }

    private var resultHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "BYTE MATCH",
            title: resultTitle,
            detail: AppLocalization.format(
                "%lld selected PDFs | %@ checked",
                report.totalCandidateCount,
                ByteCountFormatter.string(
                    fromByteCount: report.totalCandidateBytes,
                    countStyle: .file
                )
            ),
            symbol: (
                report.isCompleteOutputSet
                    || report.isCompleteRemovedSet
            )
                ? "checkmark.seal.fill"
                : "doc.text.magnifyingglass",
            tint: (
                report.isCompleteOutputSet
                    || report.isCompleteRemovedSet
            )
                ? PPColor.mint
                : PPColor.amber,
            metrics: [
                WorkflowMetric(
                    value: "\(report.outputMatchCount)",
                    label: "Numbered",
                    symbol: "checkmark.circle",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "\(report.removedMatchCount)",
                    label: "Cleared",
                    symbol: "arrow.uturn.backward.circle",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value:
                        "\(report.sourceMatchCount + report.missingCount + report.ambiguousCount)",
                    label: "Review",
                    symbol: "exclamationmark.triangle",
                    tint: PPColor.amber
                )
            ]
        )
    }

    private var explanation: some View {
        Label(
            "Matches use PDF bytes and SHA-256 only. File names are labels, not evidence.",
            systemImage: "checkmark.shield"
        )
        .font(.caption)
        .foregroundStyle(PPColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actionFooter: some View {
        VStack(spacing: PPSpacing.small) {
            if exportTask != nil {
                HStack(spacing: PPSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Signing match report".localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    chooseAgainButton
                    shareReportButton
                }
                VStack(spacing: PPSpacing.small) {
                    shareReportButton
                    chooseAgainButton
                }
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private var chooseAgainButton: some View {
        Button {
            dismiss()
            onChooseAgain()
        } label: {
            Label(
                "Choose Again",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(
            PPQuietButtonStyle(tint: PPColor.cyan)
        )
        .disabled(exportTask != nil || isSharing)
    }

    private var shareReportButton: some View {
        Button {
            isConfirmingExport = true
        } label: {
            Label(
                exportTask == nil
                    ? "Share Signed Report"
                    : "Preparing Report",
                systemImage: exportTask == nil
                    ? "square.and.arrow.up"
                    : "hourglass"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(exportTask != nil || isSharing)
    }

    private var matchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(text: "RECEIPT ORDER")
                .padding(.bottom, PPSpacing.small)
            ForEach(
                Array(report.matches.enumerated()),
                id: \.element.id
            ) { offset, match in
                matchRow(match, number: offset + 1)
                Rectangle()
                    .fill(PPColor.border.opacity(0.52))
                    .frame(height: 0.6)
                    .padding(.leading, 42)
            }
        }
    }

    private var unrecognizedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(text: "NOT IN RECEIPT")
                .padding(.bottom, PPSpacing.small)
            ForEach(report.unrecognizedCandidates) { candidate in
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "questionmark.diamond")
                        .foregroundStyle(PPColor.rose)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.fileName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Text(
                            "\(candidate.formattedSize) | SHA-256 \(candidate.shortFingerprint)"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                    }
                }
                .frame(minHeight: 54)
                .accessibilityElement(children: .combine)
                Rectangle()
                    .fill(PPColor.border.opacity(0.52))
                    .frame(height: 0.6)
                    .padding(.leading, 42)
            }
        }
    }

    private func matchRow(
        _ match: PDFBatesExternalEntryMatch,
        number: Int
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Text("\(number)")
                .font(.caption2.monospacedDigit().weight(.black))
                .foregroundStyle(PPColor.surface)
                .frame(width: 24, height: 24)
                .background(matchColor(match.status), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(match.entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Text(
                    "\(match.entry.startIdentifier) - \(match.entry.endIdentifier)"
                )
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .lineLimit(1)
                Text(candidateSummary(match))
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: PPSpacing.small)
            Image(systemName: match.status.symbol)
                .foregroundStyle(matchColor(match.status))
                .accessibilityLabel(match.status.title.localizedUI)
        }
        .frame(minHeight: 70)
        .accessibilityElement(children: .combine)
    }

    private var resultTitle: String {
        if report.isCompleteOutputSet {
            return "All numbered PDFs match"
        }
        if report.isCompleteRemovedSet {
            return "All cleared PDFs match"
        }
        if report.outputMatchCount
            + report.removedMatchCount
            + report.sourceMatchCount > 0 {
            return "Some PDFs need review"
        }
        return "No receipt PDFs matched"
    }

    private func candidateSummary(
        _ match: PDFBatesExternalEntryMatch
    ) -> String {
        guard !match.candidates.isEmpty else {
            return match.status.title.localizedUI
        }
        let names = match.candidates.prefix(2).map(\.fileName)
            .joined(separator: ", ")
        let remaining = match.candidates.count - min(
            2,
            match.candidates.count
        )
        if remaining > 0 {
            return AppLocalization.format(
                "%@ and %lld more",
                names,
                remaining
            )
        }
        return names
    }

    private func matchColor(
        _ status: PDFBatesExternalEntryMatchStatus
    ) -> Color {
        switch status {
        case .outputMatch: return PPColor.mint
        case .removedMatch, .sourceMatch: return PPColor.cyan
        case .missing, .ambiguous: return PPColor.amber
        }
    }

    private func exportReport() {
        guard exportTask == nil, !isSharing else { return }
        removeShareFile()
        exportTask = Task {
            let url = await model.exportSignedBatesMatchReport(
                receipt: receipt,
                report: report
            )
            let wasCancelled = Task.isCancelled
            exportTask = nil
            guard !wasCancelled, let url else {
                if let url {
                    try? FileManager.default.removeItem(at: url)
                }
                return
            }
            shareURL = url
            exportFeedback += 1
            isSharing = true
        }
    }

    private func removeShareFile() {
        guard let shareURL else { return }
        try? FileManager.default.removeItem(at: shareURL)
        self.shareURL = nil
    }
}

struct BatesMatchReportInspectionView: View {
    @Environment(\.dismiss) private var dismiss

    let inspection: PDFBatesMatchReportInspection

    private var report: PDFBatesExternalMatchReport {
        inspection.signedReport.payload.report
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
                        verificationHeader
                        verificationSection
                        resultSection
                        if !report.unrecognizedCandidates.isEmpty {
                            unrecognizedSection
                        }
                    }
                    .frame(maxWidth: 860)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Signed Match Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var verificationHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "BATES MATCH REPORT",
            title: verificationTitle,
            detail: inspection.detail.localizedUI,
            symbol: verificationSymbol,
            tint: verificationColor,
            metrics: [
                WorkflowMetric(
                    value: "\(report.outputMatchCount)",
                    label: "Numbered",
                    symbol: "checkmark.circle",
                    tint: evidenceVerified
                        ? PPColor.mint
                        : PPColor.rose
                ),
                WorkflowMetric(
                    value: "\(report.removedMatchCount)",
                    label: "Cleared",
                    symbol: "arrow.uturn.backward.circle",
                    tint: evidenceVerified
                        ? PPColor.cyan
                        : PPColor.rose
                ),
                WorkflowMetric(
                    value:
                        "\(report.sourceMatchCount + report.missingCount + report.ambiguousCount)",
                    label: "Review",
                    symbol: "exclamationmark.triangle",
                    tint: evidenceVerified
                        ? PPColor.amber
                        : PPColor.rose
                )
            ]
        )
    }

    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "VERIFICATION")
            fact(
                "Source file",
                value: inspection.sourceFileName,
                symbol: "doc"
            )
            fact(
                "Report signature",
                value: inspection.signatureStatus.title.localizedUI,
                symbol: inspection.signatureStatus.symbol
            )
            fact(
                "Report signer",
                value: signerTitle,
                symbol: inspection.trustStatus.symbol
            )
            fact(
                "Report Key ID",
                value: inspection.signedReport.signature.keyID,
                symbol: "key"
            )
            fact(
                "Embedded receipt",
                value:
                    inspection.receiptSignatureStatus.title.localizedUI,
                symbol:
                    inspection.receiptSignatureStatus.symbol
            )
            fact(
                "Checked",
                value: report.checkedAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                ),
                symbol: "clock"
            )
            Label(
                "This verifies the saved report and its embedded receipt. It does not re-read the listed PDFs.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, PPSpacing.small)
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

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(
                text: evidenceVerified
                    ? "SIGNED CONCLUSIONS"
                    : "UNVERIFIED CONCLUSIONS"
            )
                .padding(.bottom, PPSpacing.small)
            ForEach(
                Array(report.matches.enumerated()),
                id: \.element.id
            ) { offset, match in
                matchRow(match, number: offset + 1)
                Rectangle()
                    .fill(PPColor.border.opacity(0.52))
                    .frame(height: 0.6)
                    .padding(.leading, 42)
            }
        }
    }

    private var unrecognizedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(text: "NOT IN RECEIPT")
                .padding(.bottom, PPSpacing.small)
            ForEach(report.unrecognizedCandidates) { candidate in
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "questionmark.diamond")
                        .foregroundStyle(PPColor.rose)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.fileName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Text(
                            "\(candidate.formattedSize) | SHA-256 \(candidate.shortFingerprint)"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                    }
                }
                .frame(minHeight: 54)
                .accessibilityElement(children: .combine)
                Rectangle()
                    .fill(PPColor.border.opacity(0.52))
                    .frame(height: 0.6)
                    .padding(.leading, 42)
            }
        }
    }

    private func matchRow(
        _ match: PDFBatesExternalEntryMatch,
        number: Int
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Text("\(number)")
                .font(.caption2.monospacedDigit().weight(.black))
                .foregroundStyle(PPColor.surface)
                .frame(width: 24, height: 24)
                .background(matchColor(match.status), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(match.entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Text(
                    "\(match.entry.startIdentifier) - \(match.entry.endIdentifier)"
                )
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .lineLimit(1)
                Text(candidateSummary(match))
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: PPSpacing.small)
            Image(systemName: match.status.symbol)
                .foregroundStyle(matchColor(match.status))
                .accessibilityLabel(match.status.title.localizedUI)
        }
        .frame(minHeight: 70)
        .accessibilityElement(children: .combine)
    }

    private func fact(
        _ title: String,
        value: String,
        symbol: String
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Image(systemName: symbol)
                .foregroundStyle(verificationColor)
                .frame(width: 24)
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
            Spacer(minLength: PPSpacing.small)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(PPColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(minHeight: 34)
    }

    private var verificationTitle: String {
        guard evidenceVerified else {
            return "Match report not verified"
        }
        switch inspection.trustStatus {
        case .thisDevice:
            return "Signed report from this device"
        case .trusted:
            return "Signed report from a trusted source"
        case .unknown:
            return "Valid report, unknown signer"
        case .invalid:
            return "Match report not verified"
        case .unsupported:
            return "Unsupported match report"
        }
    }

    private var verificationSymbol: String {
        inspection.isVerified
            ? inspection.trustStatus.symbol
            : inspection.signatureStatus.symbol
    }

    private var verificationColor: Color {
        guard evidenceVerified else { return PPColor.rose }
        switch inspection.trustStatus {
        case .thisDevice, .trusted: return PPColor.mint
        case .unknown: return PPColor.amber
        case .invalid, .unsupported: return PPColor.rose
        }
    }

    private var signerTitle: String {
        inspection.trustedSignerName
            ?? inspection.trustStatus.title.localizedUI
    }

    private var evidenceVerified: Bool {
        inspection.isVerified
            && inspection.receiptSignatureStatus == .verified
    }

    private func candidateSummary(
        _ match: PDFBatesExternalEntryMatch
    ) -> String {
        guard !match.candidates.isEmpty else {
            return match.status.title.localizedUI
        }
        let names = match.candidates.prefix(2).map(\.fileName)
            .joined(separator: ", ")
        let remaining = match.candidates.count - min(
            2,
            match.candidates.count
        )
        if remaining > 0 {
            return AppLocalization.format(
                "%@ and %lld more",
                names,
                remaining
            )
        }
        return names
    }

    private func matchColor(
        _ status: PDFBatesExternalEntryMatchStatus
    ) -> Color {
        guard evidenceVerified else { return PPColor.rose }
        switch status {
        case .outputMatch: return PPColor.mint
        case .removedMatch, .sourceMatch: return PPColor.cyan
        case .missing, .ambiguous: return PPColor.amber
        }
    }
}

struct BatesBatchReceiptView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let receiptID: UUID
    var onOpenDocument: ((UUID) -> Void)?

    @State private var report:
        PDFBatesBatchReceiptVerificationReport?
    @State private var verificationTask: Task<Void, Never>?
    @State private var shareTask: Task<Void, Never>?
    @State private var isSharing = false
    @State private var shareURL: URL?
    @State private var isPreparingShare = false
    @State private var isConfirmingDeletion = false
    @State private var isConfirmingRemoval = false
    @State private var removalTask: Task<Void, Never>?
    @State private var verificationFeedback = 0
    @State private var removalFeedback = 0

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if let receipt {
                    ScrollView {
                        VStack(
                            alignment: .leading,
                            spacing: PPSpacing.large
                        ) {
                            receiptHeader(receipt)
                            signatureSection(receipt)
                            entrySection(receipt)
                        }
                        .frame(maxWidth: 860)
                        .padding(PPSpacing.regular)
                        .padding(.bottom, 96)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView(
                        "Receipt unavailable",
                        systemImage: "doc.questionmark"
                    )
                }
            }
            .navigationTitle("Bates Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(removalTask != nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            recheck()
                        } label: {
                            Label(
                                "Recheck PDFs",
                                systemImage:
                                    "arrow.triangle.2.circlepath"
                            )
                        }
                        .disabled(
                            verificationTask != nil
                                || removalTask != nil
                        )

                        Button {
                            prepareShare()
                        } label: {
                            Label(
                                "Share Signed JSON",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .disabled(
                            shareURL != nil
                                || isPreparingShare
                                || removalTask != nil
                        )

                        Divider()
                        if let receipt, receipt.removal == nil {
                            Button(role: .destructive) {
                                isConfirmingRemoval = true
                            } label: {
                                Label(
                                    "Remove Bates from Batch",
                                    systemImage:
                                        "number.square.fill"
                                )
                            }
                            .disabled(!canRemoveBates)
                        }

                        Button(role: .destructive) {
                            isConfirmingDeletion = true
                        } label: {
                            Label(
                                "Delete Receipt",
                                systemImage: "trash"
                            )
                        }
                        .disabled(removalTask != nil)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
        }
        .task(id: receiptID) {
            recheck()
        }
        .interactiveDismissDisabled(removalTask != nil)
        .onDisappear {
            verificationTask?.cancel()
            verificationTask = nil
            shareTask?.cancel()
            shareTask = nil
            removalTask?.cancel()
            removalTask = nil
            removeShareFile()
        }
        .sensoryFeedback(.success, trigger: verificationFeedback)
        .sensoryFeedback(.success, trigger: removalFeedback)
        .sheet(isPresented: $isSharing, onDismiss: removeShareFile) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .confirmationDialog(
            "Delete this local Bates receipt?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Receipt", role: .destructive) {
                Task {
                    if await model.deleteBatesBatchReceipt(
                        receiptID: receiptID
                    ) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The PDFs and their Bates numbers are not changed."
            )
        }
        .confirmationDialog(
            "Remove Bates numbers from this batch?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove from All PDFs", role: .destructive) {
                removeBates()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Only PDFs that still exactly match this signed batch will change. PaperPath will save recovery versions, remove its Bates annotations, and sign the cleared file hashes."
            )
        }
    }

    private var receipt: PDFSignedBatesBatchReceipt? {
        model.batesBatchReceipts.first {
            $0.id == receiptID
        }
    }

    private func receiptHeader(
        _ receipt: PDFSignedBatesBatchReceipt
    ) -> some View {
        WorkflowCommandHeader(
            eyebrow: "SIGNED BATES RECEIPT",
            title: reportTitle,
            detail: verificationProgress.map {
                AppLocalization.format(
                    "%lld of %lld checked | %@",
                    $0.completedDocumentCount,
                    $0.totalDocumentCount,
                    $0.currentDocumentName
                )
            } ?? report?.detail
                ?? "Checking the signature and current private copies.",
            symbol: reportSymbol,
            tint: reportColor,
            metrics: [
                WorkflowMetric(
                    value: "\(receipt.payload.documentCount)",
                    label: "PDFs",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: "\(receipt.payload.totalPageCount)",
                    label: "Pages",
                    symbol: "book.pages",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value:
                        "\(report?.currentCount ?? 0)/\(receipt.payload.documentCount)",
                    label: receipt.removal == nil
                        ? "Current"
                        : "Verified",
                    symbol: "checkmark.circle",
                    tint: report?.isCurrent == true
                        ? PPColor.mint
                        : PPColor.amber
                )
            ]
        )
    }

    private func signatureSection(
        _ receipt: PDFSignedBatesBatchReceipt
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "SIGNED MANIFEST")

            receiptFact(
                title: "Sequence",
                value:
                    "\(receipt.payload.firstIdentifier) - \(receipt.payload.lastIdentifier)",
                symbol: "number"
            )
            receiptFact(
                title: "Issued",
                value: receipt.payload.createdAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                ),
                symbol: "clock"
            )
            receiptFact(
                title: "Position",
                value: receipt.payload.position.title.localizedUI,
                symbol: receipt.payload.position.symbol
            )
            receiptFact(
                title: "Signer Key ID",
                value: receipt.signature.keyID,
                symbol: "key"
            )
            receiptFact(
                title: "Signature",
                value:
                    report?.signatureStatus.title.localizedUI
                        ?? "Checking".localizedUI,
                symbol:
                    report?.signatureStatus.symbol
                        ?? "hourglass"
            )
            if let removal = receipt.removal {
                receiptFact(
                    title: "Bates removed",
                    value: removal.payload.createdAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ),
                    symbol: "arrow.uturn.backward.circle"
                )
                receiptFact(
                    title: "Removal Key ID",
                    value: removal.signature.keyID,
                    symbol: "key.horizontal"
                )
            }
            receiptFact(
                title: "Signer",
                value: report.map {
                    $0.trustedSignerName
                        ?? $0.trustStatus.title.localizedUI
                } ?? "Checking".localizedUI,
                symbol: report?.trustStatus.symbol ?? "hourglass"
            )
            receiptFact(
                title: "Shared JSON",
                value:
                    "File names, ranges, revisions, and hashes; no PDF bytes"
                        .localizedUI,
                symbol: "doc.badge.arrow.up"
            )
        }
        .padding(.vertical, PPSpacing.small)
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

    private func entrySection(
        _ receipt: PDFSignedBatesBatchReceipt
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(text: "DOCUMENT RANGES")
                .padding(.bottom, PPSpacing.small)

            ForEach(
                Array(receipt.payload.entries.enumerated()),
                id: \.element.id
            ) { offset, entry in
                entryRow(entry, number: offset + 1)
                Rectangle()
                    .fill(PPColor.border.opacity(0.52))
                    .frame(height: 0.6)
                    .padding(.leading, 42)
            }
        }
    }

    @ViewBuilder
    private func entryRow(
        _ entry: PDFBatesBatchReceiptEntry,
        number: Int
    ) -> some View {
        let verification = report?.items.first {
            $0.entry.recordID == entry.recordID
        }
        let content = HStack(spacing: PPSpacing.small) {
            Text("\(number)")
                .font(.caption2.monospacedDigit().weight(.black))
                .foregroundStyle(PPColor.surface)
                .frame(width: 24, height: 24)
                .background(entryStatusColor(verification), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Text(
                    "\(entry.startIdentifier) - \(entry.endIdentifier)"
                )
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .lineLimit(1)
                Text(
                    AppLocalization.format(
                        "%lld pages | SHA-256 %@",
                        entry.pageCount,
                        entry.shortOutputFingerprint
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
            }

            Spacer(minLength: PPSpacing.small)

            VStack(alignment: .trailing, spacing: 3) {
                Image(
                    systemName:
                        verification?.status.symbol
                            ?? "hourglass"
                )
                .foregroundStyle(entryStatusColor(verification))
                Text(
                    verification?.status.title.localizedUI
                        ?? "Checking".localizedUI
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
            }
        }
        .frame(minHeight: 72)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(
            verification?.detail.localizedUI
                ?? "Waiting for verification".localizedUI
        )

        if let verification,
           report?.signatureStatus == .verified,
           (
               verification.status == .current
                   || verification.status == .changed
           ),
           model.record(id: entry.recordID) != nil,
           let onOpenDocument {
            Button {
                dismiss()
                onOpenDocument(entry.recordID)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open this private copy")
        } else {
            content
        }
    }

    private func receiptFact(
        title: String,
        value: String,
        symbol: String
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Image(systemName: symbol)
                .foregroundStyle(PPColor.cyan)
                .frame(width: 24)
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
            Spacer(minLength: PPSpacing.small)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(PPColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(minHeight: 34)
    }

    private var actionFooter: some View {
        VStack(spacing: PPSpacing.small) {
            if let progress = verificationProgress {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(progress.currentDocumentName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(
                            "\(progress.completedDocumentCount)/\(progress.totalDocumentCount)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                    }
                    ProgressView(value: progress.fractionCompleted)
                        .tint(PPColor.cyan)
                }
            }

            if removalTask != nil,
               let progress = model.batesBatchProgress {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(progress.stage.title.localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Spacer()
                        Text(
                            "\(progress.completedDocumentCount)/\(progress.totalDocumentCount)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                    }
                    ProgressView(value: progress.fractionCompleted)
                        .tint(PPColor.rose)
                }
            }

            if receipt?.removal == nil {
                Button {
                    isConfirmingRemoval = true
                } label: {
                    Label(
                        removalTask == nil
                            ? "Remove Bates from Batch"
                            : "Removing Bates",
                        systemImage: removalTask == nil
                            ? "number.square"
                            : "hourglass"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.rose)
                )
                .disabled(!canRemoveBates)
                .accessibilityHint(
                    "Requires every PDF to match this signed batch"
                )
            }

            HStack(spacing: PPSpacing.small) {
                Button {
                    recheck()
                } label: {
                    Label(
                        verificationTask == nil
                            ? "Recheck PDFs"
                            : "Checking",
                        systemImage:
                            verificationTask == nil
                                ? "arrow.triangle.2.circlepath"
                                : "hourglass"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
                .disabled(
                    verificationTask != nil || removalTask != nil
                )

                Button {
                    prepareShare()
                } label: {
                    Label(
                        isPreparingShare
                            ? "Preparing"
                            : "Share",
                        systemImage:
                            isPreparingShare
                                ? "hourglass"
                                : "square.and.arrow.up"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(
                    shareURL != nil
                        || isPreparingShare
                        || removalTask != nil
                )
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private var reportTitle: String {
        guard let report else { return "Checking receipt" }
        if report.signatureStatus != .verified {
            return "Receipt cannot be trusted"
        }
        if report.trustStatus == .unknown {
            return "Valid signature, unknown source"
        }
        if receipt?.removal != nil,
           report.isCurrent,
           report.removedCount == report.items.count {
            return "Batch removal matches"
        }
        return report.isCurrent
            ? "Batch still matches"
            : "Batch needs attention"
    }

    private var reportSymbol: String {
        guard let report else { return "hourglass" }
        if report.signatureStatus != .verified {
            return "xmark.seal.fill"
        }
        if report.trustStatus == .unknown {
            return report.trustStatus.symbol
        }
        if receipt?.removal != nil,
           report.isCurrent,
           report.removedCount == report.items.count {
            return "arrow.uturn.backward.circle.fill"
        }
        return report.isCurrent
            ? "checkmark.seal.fill"
            : "exclamationmark.triangle.fill"
    }

    private var reportColor: Color {
        guard let report else { return PPColor.cyan }
        if report.signatureStatus != .verified {
            return PPColor.rose
        }
        if report.trustStatus == .unknown {
            return PPColor.amber
        }
        if receipt?.removal != nil,
           report.isCurrent,
           report.removedCount == report.items.count {
            return PPColor.cyan
        }
        return report.isCurrent ? PPColor.mint : PPColor.amber
    }

    private var verificationProgress:
        PDFBatesBatchReceiptVerificationProgress? {
        guard model.batesReceiptVerificationProgress?.receiptID
                == receiptID
        else { return nil }
        return model.batesReceiptVerificationProgress
    }

    private func entryStatusColor(
        _ item: PDFBatesBatchReceiptVerificationItem?
    ) -> Color {
        guard let item else { return PPColor.textSecondary }
        switch item.status {
        case .current: return PPColor.mint
        case .removed: return PPColor.cyan
        case .changed, .inTrash: return PPColor.amber
        case .missing, .untrusted: return PPColor.rose
        }
    }

    private var canRemoveBates: Bool {
        guard let receipt,
              receipt.removal == nil,
              let report,
              report.signatureStatus == .verified,
              report.items.count == receipt.payload.entries.count,
              report.items.allSatisfy({
                  $0.status == .current
              })
        else { return false }
        return verificationTask == nil && removalTask == nil
    }

    private func recheck() {
        verificationTask?.cancel()
        verificationTask = Task {
            let verified = await model.verifyBatesBatchReceipt(
                receiptID: receiptID
            )
            guard !Task.isCancelled else { return }
            report = verified
            verificationTask = nil
            if verified != nil {
                verificationFeedback += 1
            }
        }
    }

    private func prepareShare() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        shareTask = Task {
            guard let url = await model.exportBatesBatchReceipt(
                receiptID: receiptID
            ) else {
                isPreparingShare = false
                shareTask = nil
                return
            }
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: url)
                isPreparingShare = false
                shareTask = nil
                return
            }
            isPreparingShare = false
            shareTask = nil
            shareURL = url
            isSharing = true
        }
    }

    private func removeBates() {
        guard canRemoveBates else { return }
        verificationTask?.cancel()
        verificationTask = nil
        removalTask = Task {
            let succeeded = await model.removeBatesNumbersBatch(
                receiptID: receiptID
            )
            let wasCancelled = Task.isCancelled
            removalTask = nil
            guard succeeded, !wasCancelled else { return }
            removalFeedback += 1
            recheck()
        }
    }

    private func removeShareFile() {
        guard let shareURL else { return }
        try? FileManager.default.removeItem(at: shareURL)
        self.shareURL = nil
        isSharing = false
    }
}
