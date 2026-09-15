import SwiftUI
import UniformTypeIdentifiers

private struct BatesProgressHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let completedCount: Int?
    let totalCount: Int?

    var body: some View {
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
        layout {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? 2
                        : 1
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let completedCount,
               let totalCount,
               totalCount > 0 {
                Text("\(completedCount)/\(totalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
    }
}

struct BatchBatesNumberingView: View {
    private enum FocusedField: Hashable {
        case prefix
        case suffix
        case startingNumber
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    @State private var orderedRecordIDs: [UUID]
    @State private var searchText = ""
    @State private var position = PDFPageNumberPosition.bottomRight
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var digitCount = 6
    @State private var startNumberText = "1"
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var isStopRequested = false
    @State private var successFeedback = 0
    @State private var errorFeedback = 0
    @State private var isPresentingReceiptHistory = false
    @State private var issuedReceipt:
        PDFSignedBatesBatchReceipt?
    @FocusState private var focusedField: FocusedField?

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
                        OfficeClockContinuitySection()
                        sequenceSection
                            .disabled(
                                operationTask != nil
                                    || isAnotherBatesBatchActive
                            )
                        documentSection
                            .disabled(
                                operationTask != nil
                                    || isAnotherBatesBatchActive
                            )
                    }
                    .frame(maxWidth: 860)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 108)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
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
            .submitLabel(.search)
            .onSubmit(of: .search) {
                dismissSearch()
            }
            .onChange(of: searchText) { _, value in
                if value.count > 200 {
                    searchText = String(value.prefix(200))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationTask == nil
                                ? "Cancel"
                                : isStopRequested
                                    ? "Stopping"
                                    : "Stop"
                        ).localizedUI
                    ) {
                        if operationTask != nil {
                            interruptBatchNumbering()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(operationTask != nil && isStopRequested)
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
                    .disabled(
                        operationTask != nil
                            || isAnotherBatesBatchActive
                    )
                    .accessibilityLabel("Batch selection options")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
        }
        .interactiveDismissDisabled(operationTask != nil)
        .accessibilityAction(.escape) {
            if operationTask != nil {
                interruptBatchNumbering()
            } else if focusedField != nil {
                focusedField = nil
            } else if !searchText.isEmpty {
                searchText = ""
                dismissSearch()
            } else {
                dismiss()
            }
        }
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
            if value.count > 24 {
                prefix = String(value.prefix(24))
            }
        }
        .onChange(of: suffix) { _, value in
            if value.count > 24 {
                suffix = String(value.prefix(24))
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptBatchNumbering(invalidateResult: true)
            searchText = ""
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptBatchNumbering(invalidateResult: true)
            searchText = ""
        }
        .onDisappear {
            interruptBatchNumbering(invalidateResult: true)
            searchText = ""
        }
    }

    private var batchHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "CONTINUOUS BATES",
            title: isAnotherBatesBatchActive
                ? "Bates task running in another window"
                : operationTask == nil
                    ? "One sequence across PDFs"
                    : model.batesBatchProgress?.stage.title
                        ?? "Preparing numbered copies",
            detail: operationTask == nil
                ? (
                    isAnotherBatesBatchActive
                        ? model.batesBatchProgress?
                            .currentDocumentName
                            ?? "Finish or stop that batch before starting another."
                        : "Order private copies, preview every range, then commit them together."
                )
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
                        field: .prefix,
                        text: $prefix
                    )
                    affixField(
                        title: "Suffix",
                        placeholder: "-A",
                        field: .suffix,
                        text: $suffix
                    )
                }
                VStack(spacing: PPSpacing.small) {
                    affixField(
                        title: "Prefix",
                        placeholder: "CASE-",
                        field: .prefix,
                        text: $prefix
                    )
                    affixField(
                        title: "Suffix",
                        placeholder: "-A",
                        field: .suffix,
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
                .focused($focusedField, equals: .startingNumber)
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
                Text(
                    (
                        normalizedSearchText.isEmpty
                            ? "Top to bottom"
                            : "Filtered view"
                    ).localizedUI
                )
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
            }

            if !hiddenSelectedRecordIDs.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        hiddenSelectionMessage
                        Spacer(minLength: PPSpacing.small)
                        deselectHiddenButton
                    }
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        hiddenSelectionMessage
                        deselectHiddenButton
                    }
                }
                .padding(.vertical, PPSpacing.xSmall)
            }

            if displayedRecords.isEmpty {
                VStack(spacing: PPSpacing.medium) {
                    ContentUnavailableView(
                        (
                            normalizedSearchText.isEmpty
                                ? "No eligible PDFs"
                                : "No matching PDFs"
                        ).localizedUI,
                        systemImage: normalizedSearchText.isEmpty
                            ? "doc.questionmark"
                            : "magnifyingglass",
                        description: Text(
                            (
                                normalizedSearchText.isEmpty
                                    ? "Unlocked working copies appear here."
                                    : "Try another file name."
                            ).localizedUI
                        )
                    )
                    if !normalizedSearchText.isEmpty {
                        Button {
                            searchText = ""
                            dismissSearch()
                        } label: {
                            Label(
                                "Clear Search",
                                systemImage: "xmark.circle"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(
                            PPQuietButtonStyle(tint: PPColor.amber)
                        )
                        .accessibilityIdentifier(
                            "batchBatesClearSearch"
                        )
                    }
                }
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

        return layout {
            HStack(spacing: PPSpacing.small) {
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
                    .frame(width: 44, height: 44)
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
                                    .caption2.monospacedDigit()
                                        .weight(.black)
                                )
                                .foregroundStyle(PPColor.surface)
                                .frame(width: 22, height: 22)
                                .background(PPColor.amber, in: Circle())
                        }
                        Text(record.displayName)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(
                                dynamicTypeSize.ppPrefersExpandedLayout
                                    ? 3
                                    : 2
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }

                    Text(
                        planItem.map {
                            AppLocalization.format(
                                "%lld pages | %@ to %@",
                                $0.pageCount,
                                plan?.identifier(
                                    for: $0.startNumber
                                ) ?? "",
                                plan?.identifier(
                                    for: $0.endNumber
                                ) ?? ""
                            )
                        } ?? record.subtitle
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !dynamicTypeSize.ppPrefersExpandedLayout {
                Spacer(minLength: PPSpacing.small)
            }

            if let selectedIndex, normalizedSearchText.isEmpty {
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
                .frame(
                    maxWidth:
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? .infinity
                            : nil,
                    alignment: .leading
                )
                .padding(
                    .leading,
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? 44 + PPSpacing.small
                        : 0
                )
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
                .frame(width: 44, height: 44)
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
               operationTask != nil || isAnotherBatesBatchActive {
                VStack(alignment: .leading, spacing: 5) {
                    BatesProgressHeader(
                        title: progress.stage.title.localizedUI,
                        completedCount:
                            progress.completedDocumentCount,
                        totalCount: progress.totalDocumentCount
                    )
                    ProgressView(value: progress.fractionCompleted)
                        .tint(PPColor.cyan)
                        .accessibilityLabel("Bates numbering progress")
                        .accessibilityValue(
                            AppLocalization.format(
                                "%lld of %lld PDFs processed",
                                progress.completedDocumentCount,
                                progress.totalDocumentCount
                            )
                        )
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
        if operationTask != nil {
            Button {
                interruptBatchNumbering()
            } label: {
                HStack(spacing: PPSpacing.small) {
                    Image(
                        systemName: isStopRequested
                            ? "hourglass"
                            : "stop.fill"
                    )
                    Text(
                        (
                            isStopRequested
                                ? "Stopping"
                                : "Stop safely"
                        ).localizedUI
                    )
                    Spacer()
                }
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
            .disabled(isStopRequested)
        } else {
            Button {
                apply()
            } label: {
                HStack(spacing: PPSpacing.small) {
                    Image(
                        systemName: isAnotherBatesBatchActive
                            ? "hourglass"
                            : "number.square.fill"
                    )
                    Text(
                        isAnotherBatesBatchActive
                            ? "Bates task running".localizedUI
                            : AppLocalization.format(
                                "Bates number %lld PDFs",
                                orderedRecordIDs.count
                            )
                    )
                    Spacer()
                    if !isAnotherBatesBatchActive {
                        Image(systemName: "arrow.right")
                    }
                }
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(
                plan == nil || isAnotherBatesBatchActive
            )
            .accessibilityHint(
                (
                    isAnotherBatesBatchActive
                        ? "Finish or stop the Bates task in the other window."
                        : validationMessage
                            ?? "Creates verified numbered copies in the shown order."
                ).localizedUI
            )
        }
    }

    private var isAnotherBatesBatchActive: Bool {
        operationTask == nil
            && model.isBatesBatchMutationActive
    }

    private func affixField(
        title: String,
        placeholder: String,
        field: FocusedField,
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
                .focused($focusedField, equals: field)
                .submitLabel(.done)
                .onSubmit {
                    focusedField = nil
                }
        }
    }

    private var hiddenSelectionMessage: some View {
        Label(
            AppLocalization.format(
                "%lld selected outside this search",
                hiddenSelectedRecordIDs.count
            ),
            systemImage: "eye.slash"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.amber)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var deselectHiddenButton: some View {
        Button {
            let hiddenIDs = Set(hiddenSelectedRecordIDs)
            orderedRecordIDs.removeAll {
                hiddenIDs.contains($0)
            }
        } label: {
            Label(
                "Deselect Hidden",
                systemImage: "minus.circle"
            )
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
        .accessibilityHint(
            "Removes only selected PDFs hidden by the current search."
                .localizedUI
        )
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
        guard !normalizedSearchText.isEmpty else {
            return eligibleRecords
        }
        return eligibleRecords.filter {
            $0.displayName.localizedCaseInsensitiveContains(
                normalizedSearchText
            )
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private var hiddenSelectedRecordIDs: [UUID] {
        guard !normalizedSearchText.isEmpty else { return [] }
        let visibleIDs = Set(filteredEligibleRecords.map(\.id))
        return orderedRecordIDs.filter {
            !visibleIDs.contains($0)
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
        guard !model.isBatesBatchMutationActive,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        guard let plan else {
            errorFeedback += 1
            return
        }
        let previousReceiptID = model.batesBatchReceipts.first?.id
        let generation = UUID()
        operationGeneration = generation
        isStopRequested = false
        operationTask = Task { @MainActor in
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.applyBatesNumbersBatch(plan)
            }
            guard operationGeneration == generation else { return }
            let wasStopped =
                isStopRequested || Task.isCancelled
            operationTask = nil
            isStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    succeeded
                        ? "Bates numbering finished before stopping · receipt kept in History"
                        : "Bates numbering stopped"
                ).localizedUI
                return
            }
            guard succeeded else {
                errorFeedback += 1
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

    private func interruptBatchNumbering(
        invalidateResult: Bool = false
    ) {
        guard operationTask != nil else { return }
        if invalidateResult {
            operationGeneration = UUID()
        } else {
            guard !isStopRequested else { return }
            isStopRequested = true
        }
        operationTask?.cancel()
        if invalidateResult {
            operationTask = nil
            isStopRequested = false
        }
    }
}

struct BatesBatchReceiptHistoryView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var searchText = ""
    @State private var selectedReceipt:
        PDFSignedBatesBatchReceipt?
    @State private var pendingDocumentID: UUID?
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
    @State private var inspectionGeneration = UUID()
    @State private var matchInspectionGeneration = UUID()
    @State private var documentOpenTask: Task<Void, Never>?
    @State private var documentOpenGeneration = UUID()

    var onOpenDocument: ((UUID) -> Void)?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if filteredReceipts.isEmpty {
                    VStack(spacing: PPSpacing.medium) {
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
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                                dismissSearch()
                            } label: {
                                Label(
                                    "Clear Search",
                                    systemImage: "xmark.circle"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(
                                PPQuietButtonStyle(
                                    tint: PPColor.amber
                                )
                            )
                            .accessibilityIdentifier(
                                "batesReceiptClearSearch"
                            )
                        }
                    }
                    .frame(maxWidth: 520)
                    .padding(PPSpacing.regular)
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
            .submitLabel(.search)
            .onSubmit(of: .search) {
                dismissSearch()
            }
            .onChange(of: searchText) { _, value in
                if value.count > 200 {
                    searchText = String(value.prefix(200))
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        (
                            hasActiveInspection
                                ? "Stop"
                                : "Close"
                        ).localizedUI
                    ) {
                        if hasActiveInspection {
                            stopExternalInspections()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
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
                        .disabled(
                            model.isBatesReceiptVerificationActive
                                || model.isBatesBatchMutationActive
                        )
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
                        ZStack {
                            if isInspectingReceipt
                                || isInspectingMatchReport {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(
                                    systemName:
                                        "doc.badge.magnifyingglass"
                                )
                            }
                        }
                        .frame(width: 44, height: 44)
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
                    model.present(error, in: paperPathSceneID)
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
                    model.present(error, in: paperPathSceneID)
                }
                return
            }
            inspectExternalMatchReport(url)
        }
        .sheet(
            item: $selectedReceipt,
            onDismiss: completeDocumentOpen
        ) { receipt in
            BatesBatchReceiptView(
                receiptID: receipt.id,
                onOpenDocument: nestedDocumentOpenAction
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
            if isInspectingReceipt
                || isInspectingMatchReport
                || isAnotherReceiptVerificationActive {
                externalVerificationProgress
            }
        }
        .interactiveDismissDisabled(hasActiveInspection)
        .accessibilityAction(.escape) {
            if hasActiveInspection {
                stopExternalInspections()
            } else if !searchText.isEmpty {
                searchText = ""
                dismissSearch()
            } else {
                dismiss()
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
                    _ = await model.withFeedbackTarget(paperPathSceneID) {
                        await model.deleteBatesBatchReceipt(
                            receiptID: receipt.id
                        )
                    }
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptProtectedReceiptHistory()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtectedReceiptHistory()
        }
        .onDisappear {
            interruptProtectedReceiptHistory()
        }
    }

    private var nestedDocumentOpenAction: ((UUID) -> Void)? {
        guard onOpenDocument != nil else { return nil }
        return { recordID in
            pendingDocumentID = recordID
            selectedReceipt = nil
        }
    }

    private var hasActiveInspection: Bool {
        isInspectingReceipt || isInspectingMatchReport
    }

    private var isAnotherReceiptVerificationActive: Bool {
        !isInspectingReceipt
            && model.isBatesReceiptVerificationActive
    }

    private func completeDocumentOpen() {
        guard let recordID = pendingDocumentID else { return }
        pendingDocumentID = nil
        let generation = UUID()
        documentOpenGeneration = generation
        documentOpenTask?.cancel()
        documentOpenTask = Task { @MainActor in
            defer {
                if documentOpenGeneration == generation {
                    documentOpenTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  documentOpenGeneration == generation,
                  scenePhase == .active,
                  model.record(id: recordID) != nil
            else { return }
            onOpenDocument?(recordID)
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
        return Button {
            selectedReceipt = receipt
        } label: {
            layout {
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
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? 2
                            : 1
                    )

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
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? 2
                            : 1
                    )

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
                .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer(minLength: PPSpacing.small)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PPColor.mint)
                }
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
            BatesProgressHeader(
                title:
                    isInspectingMatchReport
                        ? "Reading signed match report".localizedUI
                        : isAnotherReceiptVerificationActive
                            ? "Receipt check running in another window"
                                .localizedUI
                        : (
                            model.batesReceiptVerificationProgress?
                                .currentDocumentName
                                ?? "Reading signed receipt".localizedUI
                        ),
                completedCount:
                    model.batesReceiptVerificationProgress?
                        .completedDocumentCount,
                totalCount:
                    model.batesReceiptVerificationProgress?
                        .totalDocumentCount
            )
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
        guard !isInspectingMatchReport,
              !model.isBatesReceiptVerificationActive,
              !model.isBatesBatchMutationActive
        else { return }
        inspectionTask?.cancel()
        let generation = UUID()
        inspectionGeneration = generation
        isInspectingReceipt = true
        inspectionTask = Task { @MainActor in
            let inspection = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.inspectExternalBatesBatchReceipt(
                    at: url
                )
            }
            guard inspectionGeneration == generation else { return }
            isInspectingReceipt = false
            inspectionTask = nil
            guard !Task.isCancelled else { return }
            importedInspection = inspection
        }
    }

    private func inspectExternalMatchReport(_ url: URL) {
        guard !isInspectingReceipt else { return }
        matchInspectionTask?.cancel()
        let generation = UUID()
        matchInspectionGeneration = generation
        isInspectingMatchReport = true
        matchInspectionTask = Task { @MainActor in
            let inspection = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.inspectExternalBatesMatchReport(
                    at: url
                )
            }
            guard matchInspectionGeneration == generation else { return }
            isInspectingMatchReport = false
            matchInspectionTask = nil
            guard !Task.isCancelled else { return }
            importedMatchInspection = inspection
        }
    }

    private func stopExternalInspections() {
        inspectionGeneration = UUID()
        matchInspectionGeneration = UUID()
        inspectionTask?.cancel()
        inspectionTask = nil
        matchInspectionTask?.cancel()
        matchInspectionTask = nil
        isInspectingReceipt = false
        isInspectingMatchReport = false
    }

    private func interruptProtectedReceiptHistory() {
        documentOpenGeneration = UUID()
        documentOpenTask?.cancel()
        documentOpenTask = nil
        stopExternalInspections()
        searchText = ""
        selectedReceipt = nil
        receiptPendingDeletion = nil
        importedInspection = nil
        importedMatchInspection = nil
        isImportingReceipt = false
        isImportingMatchReport = false
    }
}

struct ExternalBatesReceiptView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let inspection: PDFBatesBatchReceiptInspection

    @State private var isSaving = false
    @State private var saveFeedback = 0
    @State private var isSelectingPDFs = false
    @State private var matchTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var matchReport: PDFBatesExternalMatchReport?
    @State private var shouldChooseAgainAfterMatch = false
    @State private var matchGeneration = UUID()
    @State private var saveGeneration = UUID()
    @State private var sourceSelectionTask: Task<Void, Never>?
    @State private var sourceSelectionGeneration = UUID()

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
                        if matchTask != nil || saveTask != nil {
                            cancelProtectedReceiptWork()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
        }
        .interactiveDismissDisabled(
            isSaving || matchTask != nil
        )
        .accessibilityAction(.escape) {
            if matchTask != nil || saveTask != nil {
                cancelProtectedReceiptWork()
            } else {
                dismiss()
            }
        }
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
                    model.present(error, in: paperPathSceneID)
                }
                return
            }
            match(urls)
        }
        .sheet(
            item: $matchReport,
            onDismiss: completeMatchResultDismissal
        ) { report in
            ExternalBatesFileMatchView(
                receipt: inspection.receipt,
                report: report
            ) {
                shouldChooseAgainAfterMatch = true
                matchReport = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            cancelProtectedReceiptWork()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            cancelProtectedReceiptWork()
        }
        .onDisappear {
            cancelProtectedReceiptWork()
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
                            .lineLimit(dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1)
                        Text(
                            "\(item.entry.startIdentifier) - \(item.entry.endIdentifier)"
                        )
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(PPColor.amber)
                        .lineLimit(dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1)
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
                    BatesProgressHeader(
                        title: progress.currentFileName,
                        completedCount: progress.completedFileCount,
                        totalCount: progress.totalFileCount
                    )
                    ProgressView(value: progress.fractionCompleted)
                        .tint(PPColor.cyan)
                        .accessibilityLabel("Bates file match progress")
                        .accessibilityValue(
                            AppLocalization.format(
                                "%lld of %lld PDFs checked",
                                progress.completedFileCount,
                                progress.totalFileCount
                            )
                        )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    matchPDFButton
                    keepReceiptButton
                }
                VStack(spacing: PPSpacing.small) {
                    matchPDFButton
                    keepReceiptButton
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

    private var matchPDFButton: some View {
        Button {
            if matchTask != nil {
                cancelProtectedReceiptWork()
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
    }

    private var keepReceiptButton: some View {
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
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    HStack(spacing: PPSpacing.small) {
                        Image(systemName: symbol)
                            .foregroundStyle(PPColor.cyan)
                            .frame(width: 24)
                        Text(title.localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                PPColor.textSecondary
                            )
                    }
                    Text(value)
                        .font(.caption.monospaced())
                        .foregroundStyle(PPColor.textPrimary)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                }
            } else {
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
            }
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
              saveTask == nil, matchTask == nil,
              inspection.report.signatureStatus == .verified
        else { return }
        isSaving = true
        let generation = UUID()
        saveGeneration = generation
        saveTask = Task { @MainActor in
            let saved = await model.withFeedbackTarget(paperPathSceneID) {
                await model.retainExternalBatesBatchReceipt(
                    inspection.receipt
                )
            }
            guard saveGeneration == generation else { return }
            isSaving = false
            saveTask = nil
            guard saved else { return }
            saveFeedback += 1
            dismiss()
        }
    }

    private func match(_ urls: [URL]) {
        matchTask?.cancel()
        let generation = UUID()
        matchGeneration = generation
        matchTask = Task { @MainActor in
            let report = await model.withFeedbackTarget(paperPathSceneID) {
                await model.matchExternalBatesPDFs(
                    receipt: inspection.receipt,
                    candidateURLs: urls
                )
            }
            guard matchGeneration == generation else { return }
            matchTask = nil
            guard !Task.isCancelled else { return }
            matchReport = report
        }
    }

    private func cancelProtectedReceiptWork() {
        sourceSelectionGeneration = UUID()
        sourceSelectionTask?.cancel()
        sourceSelectionTask = nil
        matchGeneration = UUID()
        saveGeneration = UUID()
        matchTask?.cancel()
        matchTask = nil
        saveTask?.cancel()
        saveTask = nil
        isSelectingPDFs = false
        matchReport = nil
        shouldChooseAgainAfterMatch = false
        isSaving = false
    }

    private func completeMatchResultDismissal() {
        guard shouldChooseAgainAfterMatch else { return }
        shouldChooseAgainAfterMatch = false
        let generation = UUID()
        sourceSelectionGeneration = generation
        sourceSelectionTask?.cancel()
        sourceSelectionTask = Task { @MainActor in
            defer {
                if sourceSelectionGeneration == generation {
                    sourceSelectionTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  sourceSelectionGeneration == generation,
                  scenePhase == .active
            else { return }
            isSelectingPDFs = true
        }
    }
}

struct ExternalBatesFileMatchView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let receipt: PDFSignedBatesBatchReceipt
    let report: PDFBatesExternalMatchReport
    let onChooseAgain: () -> Void

    @State private var exportTask: Task<Void, Never>?
    @State private var shareURL: URL?
    @State private var isSharing = false
    @State private var isConfirmingExport = false
    @State private var exportFeedback = 0
    @State private var exportGeneration = UUID()

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
                    Button(
                        (exportTask == nil ? "Close" : "Stop").localizedUI
                    ) {
                        if exportTask != nil {
                            interruptProtectedExport()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
        }
        .interactiveDismissDisabled(exportTask != nil)
        .accessibilityAction(.escape) {
            if exportTask != nil {
                interruptProtectedExport()
            } else {
                dismiss()
            }
        }
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptProtectedExport()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtectedExport()
        }
        .onDisappear {
            interruptProtectedExport()
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
                            .lineLimit(
                                dynamicTypeSize.ppPrefersExpandedLayout
                                    ? 2
                                    : 1
                            )
                        Text(
                            "\(candidate.formattedSize) | SHA-256 \(candidate.shortFingerprint)"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? 2
                                : 1
                        )
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
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? 2
                            : 1
                    )
                Text(
                    "\(match.entry.startIdentifier) - \(match.entry.endIdentifier)"
                )
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .lineLimit(dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1)
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
        let generation = UUID()
        exportGeneration = generation
        exportTask = Task { @MainActor in
            let url = await model.withFeedbackTarget(paperPathSceneID) {
                await model.exportSignedBatesMatchReport(
                    receipt: receipt,
                    report: report
                )
            }
            guard exportGeneration == generation else {
                if let url {
                    await model.discardTemporaryExportCopies(at: [url])
                }
                return
            }
            exportTask = nil
            guard !Task.isCancelled, let url else {
                if let url {
                    await model.discardTemporaryExportCopies(at: [url])
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
        self.shareURL = nil
        Task {
            await model.discardTemporaryExportCopies(at: [shareURL])
        }
    }

    private func interruptProtectedExport() {
        exportGeneration = UUID()
        exportTask?.cancel()
        exportTask = nil
        isSharing = false
        removeShareFile()
    }
}

struct BatesMatchReportInspectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .accessibilityAction(.escape) {
            dismiss()
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
                            .lineLimit(dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1)
                        Text(
                            "\(candidate.formattedSize) | SHA-256 \(candidate.shortFingerprint)"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1)
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
                    .lineLimit(dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1)
                Text(
                    "\(match.entry.startIdentifier) - \(match.entry.endIdentifier)"
                )
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .lineLimit(dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1)
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
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    HStack(spacing: PPSpacing.small) {
                        Image(systemName: symbol)
                            .foregroundStyle(verificationColor)
                            .frame(width: 24)
                        Text(title.localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                PPColor.textSecondary
                            )
                    }
                    Text(value)
                        .font(.caption.monospaced())
                        .foregroundStyle(PPColor.textPrimary)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                }
            } else {
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
            }
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
        if inspection.isVerified {
            return inspection.trustStatus.symbol
        }
        return inspection.signatureStatus == .verified
            ? inspection.receiptSignatureStatus.symbol
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

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
    @State private var errorFeedback = 0
    @State private var verificationFailed = false
    @State private var verificationGeneration = UUID()
    @State private var shareGeneration = UUID()
    @State private var removalGeneration = UUID()

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
                    Button(
                        (hasActiveTask ? "Stop" : "Close").localizedUI
                    ) {
                        if hasActiveTask {
                            stopActiveReceiptTask()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
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
        .interactiveDismissDisabled(hasActiveTask)
        .accessibilityAction(.escape) {
            if hasActiveTask {
                stopActiveReceiptTask()
            } else {
                dismiss()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                interruptProtectedReceiptWork()
            } else if phase == .active {
                recheck()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtectedReceiptWork()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            guard scenePhase == .active else { return }
            recheck()
        }
        .onDisappear {
            interruptProtectedReceiptWork()
        }
        .sensoryFeedback(.success, trigger: verificationFeedback)
        .sensoryFeedback(.success, trigger: removalFeedback)
        .sensoryFeedback(.error, trigger: errorFeedback)
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
                    let deleted = await model.withFeedbackTarget(paperPathSceneID) {
                        await model.deleteBatesBatchReceipt(
                            receiptID: receiptID
                        )
                    }
                    if deleted {
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
                ?? (
                    verificationFailed
                        ? "Receipt verification failed. Recheck when the private copies are available."
                        : "Checking the signature and current private copies."
                ),
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
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(
                HStackLayout(
                    alignment: .center,
                    spacing: PPSpacing.small
                )
            )
        let content = layout {
            HStack(alignment: .top, spacing: PPSpacing.small) {
                Text("\(number)")
                    .font(.caption2.monospacedDigit().weight(.black))
                    .foregroundStyle(PPColor.surface)
                    .frame(width: 24, height: 24)
                    .background(
                        entryStatusColor(verification),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayName)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout ? 3 : 1
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "\(entry.startIdentifier) - \(entry.endIdentifier)"
                    )
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        AppLocalization.format(
                            "%lld pages | SHA-256 %@",
                            entry.pageCount,
                            entry.shortOutputFingerprint
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            if !dynamicTypeSize.ppPrefersExpandedLayout {
                Spacer(minLength: PPSpacing.small)
            }

            HStack(spacing: PPSpacing.xSmall) {
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
            .frame(
                maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                    ? .infinity
                    : nil,
                alignment: .leading
            )
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
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    HStack(spacing: PPSpacing.small) {
                        Image(systemName: symbol)
                            .foregroundStyle(PPColor.cyan)
                            .frame(width: 24)
                        Text(title.localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                PPColor.textSecondary
                            )
                    }
                    Text(value)
                        .font(.caption.monospaced())
                        .foregroundStyle(PPColor.textPrimary)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                }
            } else {
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
            }
        }
        .frame(minHeight: 34)
    }

    private var actionFooter: some View {
        VStack(spacing: PPSpacing.small) {
            if let progress = verificationProgress {
                VStack(alignment: .leading, spacing: 5) {
                    BatesProgressHeader(
                        title: progress.currentDocumentName,
                        completedCount:
                            progress.completedDocumentCount,
                        totalCount: progress.totalDocumentCount
                    )
                    ProgressView(value: progress.fractionCompleted)
                        .tint(PPColor.cyan)
                        .accessibilityLabel("Batch verification progress")
                        .accessibilityValue(
                            AppLocalization.format(
                                "%lld of %lld PDFs checked",
                                progress.completedDocumentCount,
                                progress.totalDocumentCount
                            )
                        )
                }
            }

            if removalTask != nil,
               let progress = model.batesBatchProgress {
                VStack(alignment: .leading, spacing: 5) {
                    BatesProgressHeader(
                        title: progress.stage.title.localizedUI,
                        completedCount:
                            progress.completedDocumentCount,
                        totalCount: progress.totalDocumentCount
                    )
                    ProgressView(value: progress.fractionCompleted)
                        .tint(PPColor.rose)
                        .accessibilityLabel("Bates removal progress")
                        .accessibilityValue(
                            AppLocalization.format(
                                "%lld of %lld PDFs processed",
                                progress.completedDocumentCount,
                                progress.totalDocumentCount
                            )
                        )
                }
            }

            if model.isBatesBatchMutationActive,
               removalTask == nil {
                Label(
                    "Another Bates batch is updating PDFs.",
                    systemImage: "hourglass"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.updatesFrequently)
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    recheckButton
                    shareButton
                }
                VStack(spacing: PPSpacing.small) {
                    shareButton
                    recheckButton
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

    private var recheckButton: some View {
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
            verificationTask != nil
                || removalTask != nil
                || model.isBatesBatchMutationActive
                || model.isBatesReceiptVerificationActive
        )
    }

    private var shareButton: some View {
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

    private var reportTitle: String {
        guard let report else {
            return verificationFailed
                ? "Couldn’t verify receipt"
                : "Checking receipt"
        }
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
        guard let report else {
            return verificationFailed
                ? "exclamationmark.triangle.fill"
                : "hourglass"
        }
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
        guard let report else {
            return verificationFailed ? PPColor.rose : PPColor.cyan
        }
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
        return verificationTask == nil
            && removalTask == nil
            && !model.isBatesBatchMutationActive
            && !model.isBatesReceiptVerificationActive
    }

    private var hasActiveTask: Bool {
        verificationTask != nil
            || shareTask != nil
            || removalTask != nil
    }

    private func recheck() {
        guard !model.isBatesBatchMutationActive,
              !model.isBatesReceiptVerificationActive
        else { return }
        verificationTask?.cancel()
        let generation = UUID()
        verificationGeneration = generation
        verificationFailed = false
        verificationTask = Task { @MainActor in
            let verified = await model.withFeedbackTarget(paperPathSceneID) {
                await model.verifyBatesBatchReceipt(
                    receiptID: receiptID
                )
            }
            guard verificationGeneration == generation else { return }
            verificationTask = nil
            guard !Task.isCancelled else { return }
            report = verified
            if verified != nil {
                verificationFeedback += 1
            } else {
                verificationFailed = true
                errorFeedback += 1
            }
        }
    }

    private func prepareShare() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        let generation = UUID()
        shareGeneration = generation
        shareTask = Task { @MainActor in
            let exportedURL = await model.withFeedbackTarget(paperPathSceneID) {
                await model.exportBatesBatchReceipt(
                    receiptID: receiptID
                )
            }
            guard let url = exportedURL else {
                guard shareGeneration == generation else { return }
                isPreparingShare = false
                shareTask = nil
                if !Task.isCancelled {
                    errorFeedback += 1
                }
                return
            }
            guard shareGeneration == generation else {
                await model.discardTemporaryExportCopies(at: [url])
                return
            }
            guard !Task.isCancelled else {
                await model.discardTemporaryExportCopies(at: [url])
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
        let generation = UUID()
        removalGeneration = generation
        removalTask = Task { @MainActor in
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.removeBatesNumbersBatch(
                    receiptID: receiptID
                )
            }
            guard removalGeneration == generation else { return }
            removalTask = nil
            guard succeeded else {
                if !Task.isCancelled {
                    errorFeedback += 1
                }
                return
            }
            removalFeedback += 1
            recheck()
        }
    }

    private func removeShareFile() {
        guard let shareURL else { return }
        self.shareURL = nil
        isSharing = false
        Task {
            await model.discardTemporaryExportCopies(at: [shareURL])
        }
    }

    private func stopActiveReceiptTask() {
        if removalTask != nil {
            // A committed atomic removal must still be acknowledged.
            removalTask?.cancel()
        } else if shareTask != nil {
            stopSharePreparation()
        } else {
            stopVerification()
        }
    }

    private func stopVerification() {
        verificationGeneration = UUID()
        verificationTask?.cancel()
        verificationTask = nil
    }

    private func stopSharePreparation() {
        shareGeneration = UUID()
        shareTask?.cancel()
        shareTask = nil
        isPreparingShare = false
        removeShareFile()
    }

    private func interruptProtectedReceiptWork() {
        stopVerification()
        stopSharePreparation()
        isSharing = false
        removalGeneration = UUID()
        removalTask?.cancel()
        removalTask = nil
    }
}
