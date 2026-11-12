import SwiftUI

struct StampPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let pageIndex: Int
    let onSelect: (PDFStampKind) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PPSpacing.large) {
                    Text(AppLocalization.format("Page %lld", pageIndex + 1))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)

                    LazyVGrid(
                        columns: stampColumns,
                        spacing: PPSpacing.small
                    ) {
                        ForEach(PDFStampKind.allCases) { kind in
                            Button {
                                onSelect(kind)
                            } label: {
                                HStack(spacing: PPSpacing.medium) {
                                    stampPreview(kind)
                                    Spacer()
                                    Image(systemName: "plus")
                                        .font(.caption.bold())
                                        .foregroundStyle(tint(for: kind))
                                }
                                .padding(.horizontal, PPSpacing.small)
                                .frame(minHeight: 54)
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(
                                            tint(for: kind).opacity(0.48)
                                        )
                                        .frame(height: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(
                                AppLocalization.format(
                                    "Adds %@ to page %lld",
                                    kind.title.localizedUI.lowercased(),
                                    pageIndex + 1
                                )
                            )
                            .accessibilityIdentifier(
                                "stampOption-\(kind.rawValue)"
                            )
                        }
                    }
                }
                .frame(maxWidth: 760)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background(PPCanvas())
            .navigationTitle("Add stamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .accessibilityAction(.escape) {
            dismiss()
        }
    }

    private var stampColumns: [GridItem] {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(
                .adaptive(
                    minimum: 210,
                    maximum: 320
                ),
                spacing: PPSpacing.small
            )
        ]
    }

    private func stampPreview(_ kind: PDFStampKind) -> some View {
        Text(kind.title.localizedUI.uppercased())
            .font(.caption2.smallCaps().weight(.bold))
            .fontDesign(.monospaced)
            .foregroundStyle(tint(for: kind))
            .lineLimit(
                dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
            )
            .minimumScaleFactor(
                dynamicTypeSize.ppPrefersExpandedLayout ? 1 : 0.72
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 30)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(tint(for: kind), lineWidth: 1.2)
            }
            .rotationEffect(.degrees(-2))
            .accessibilityHidden(true)
    }

    private func tint(for kind: PDFStampKind) -> Color {
        switch kind {
        case .approved:
            return PPColor.mint
        case .draft:
            return PPColor.amber
        case .confidential, .void:
            return .red
        case .final:
            return PPColor.accent
        }
    }
}

private enum PDFPageBatchScope:
    String,
    CaseIterable,
    Identifiable {
    case all
    case range
    case odd
    case even

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .range: return "Range"
        case .odd: return "Odd"
        case .even: return "Even"
        }
    }

    func selectionCount(
        pageCount: Int,
        rangeStart: Int,
        rangeEnd: Int
    ) -> Int {
        switch self {
        case .all:
            return pageCount
        case .range:
            let lowerBound = min(
                max(1, rangeStart),
                pageCount
            ) - 1
            let upperBound = min(
                max(rangeEnd, lowerBound + 1),
                pageCount
            )
            return max(0, upperBound - lowerBound)
        case .odd:
            return (pageCount + 1) / 2
        case .even:
            return pageCount / 2
        }
    }

    func pageIndices(
        pageCount: Int,
        rangeStart: Int,
        rangeEnd: Int
    ) -> [Int] {
        switch self {
        case .all:
            return Array(0..<pageCount)
        case .range:
            let lowerBound = min(
                max(1, rangeStart),
                pageCount
            ) - 1
            let upperBound = min(
                max(rangeEnd, lowerBound + 1),
                pageCount
            )
            guard lowerBound < upperBound else { return [] }
            return Array(lowerBound..<upperBound)
        case .odd:
            return Array(stride(from: 0, to: pageCount, by: 2))
        case .even:
            return Array(stride(from: 1, to: pageCount, by: 2))
        }
    }
}

struct PageNumberingSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let pageCount: Int
    let onApply: (PDFPageNumberingPayload) async -> Bool
    let onRemoveAll: () async -> Bool

    @State private var scope = PDFPageBatchScope.all
    @State private var format = PDFPageNumberFormat.pageOfTotal
    @State private var position = PDFPageNumberPosition.bottomCenter
    @State private var startNumber = 1
    @State private var rangeStart = 1
    @State private var rangeEnd: Int
    @State private var isApplying = false
    @State private var isConfirmingRemoval = false
    @State private var successFeedback = 0
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var operationStopRequested = false
    @State private var didCommitUpdate = false

    init(
        pageCount: Int,
        onApply: @escaping (
            PDFPageNumberingPayload
        ) async -> Bool,
        onRemoveAll: @escaping () async -> Bool
    ) {
        self.pageCount = max(1, pageCount)
        self.onApply = onApply
        self.onRemoveAll = onRemoveAll
        _rangeEnd = State(initialValue: max(1, pageCount))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.large
                ) {
                    WorkflowCommandHeader(
                        eyebrow: "PAGE NUMBERING",
                        title: "Number pages",
                        symbol: "number.square",
                        tint: PPColor.accent,
                        metrics: [
                            WorkflowMetric(
                                value: "\(selectedPageCount)",
                                label: "Pages",
                                symbol: "doc.on.doc",
                                tint: PPColor.accent
                            ),
                            WorkflowMetric(
                                value: "\(startNumber)",
                                label: "Starts",
                                symbol: "number",
                                tint: PPColor.cyan
                            ),
                            WorkflowMetric(
                                value: position.title,
                                label: "Position",
                                symbol: position.symbol,
                                tint: PPColor.mint
                            )
                        ]
                    )

                    numberPreview
                    scopeControls
                        .disabled(isApplying || didCommitUpdate)
                    numberingControls
                        .disabled(isApplying || didCommitUpdate)
                }
                .frame(maxWidth: 760)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background(PPCanvas())
            .navigationTitle("Page numbers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationStopRequested
                                ? "Stopping"
                                : isApplying
                                    ? "Stop"
                                    : didCommitUpdate
                                        ? "Done"
                                        : "Cancel"
                        ).localizedUI
                    ) {
                        if isApplying {
                            interruptOperation()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(operationStopRequested)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            isConfirmingRemoval = true
                        } label: {
                            Label(
                                "Remove Generated Numbers",
                                systemImage: "number.square.fill"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isApplying || didCommitUpdate)
                    .accessibilityLabel("Page number options")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                applyBar
            }
        }
        .interactiveDismissDisabled(isApplying)
        .accessibilityAction(.escape) {
            if isApplying {
                interruptOperation()
            } else {
                dismiss()
            }
        }
        .confirmationDialog(
            "Remove all PaperPath page numbers?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(
                "Remove Generated Numbers",
                role: .destructive
            ) {
                removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Other annotations are not changed.")
        }
        .sensoryFeedback(.success, trigger: successFeedback)
        .onChange(of: selectedPageCount) { _, _ in
            startNumber = min(
                startNumber,
                maximumStartNumber
            )
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptOperation(invalidateResult: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptOperation(invalidateResult: true)
        }
        .onDisappear {
            interruptOperation(invalidateResult: true)
        }
    }

    private var numberPreview: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "PREVIEW")
            ZStack(alignment: previewAlignment) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(PPColor.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(
                                PPColor.border.opacity(0.75),
                                lineWidth: 0.7
                            )
                    }
                    .aspectRatio(0.72, contentMode: .fit)
                    .frame(maxHeight: 250)
                    .shadow(
                        color: .black.opacity(0.1),
                        radius: 4,
                        y: 2
                    )

                Text(previewText)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(PPColor.textPrimary.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AppLocalization.format(
                    "Preview: %@",
                    previewText
                )
            )
        }
    }

    private var scopeControls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "PAGES")
            scopePicker

            if scope == .range {
                let layout = dynamicTypeSize.ppPrefersExpandedLayout
                    ? AnyLayout(VStackLayout(spacing: PPSpacing.small))
                    : AnyLayout(HStackLayout(spacing: PPSpacing.small))
                layout {
                    Stepper(
                        AppLocalization.format(
                            "First page %lld",
                            rangeStart
                        ),
                        value: $rangeStart,
                        in: 1...max(1, rangeEnd)
                    )
                    Stepper(
                        AppLocalization.format(
                            "Last page %lld",
                            rangeEnd
                        ),
                        value: $rangeEnd,
                        in: min(rangeStart, pageCount)...pageCount
                    )
                }
                .font(.subheadline.monospacedDigit())
            }

            if selectedPageCount > 10_000 {
                Label(
                    "Choose no more than 10,000 pages.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
            }
        }
        .padding(.bottom, PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var numberingControls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "FORMAT")

            formatPicker

            let layout = dynamicTypeSize.ppPrefersExpandedLayout
                ? AnyLayout(
                    VStackLayout(
                        alignment: .leading,
                        spacing: PPSpacing.xSmall
                    )
                )
                : AnyLayout(
                    HStackLayout(spacing: PPSpacing.medium)
                )
            layout {
                Label("Position", systemImage: position.symbol)
                    .font(.subheadline.weight(.semibold))
                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer(minLength: 0)
                }
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
                .frame(
                    maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                        ? .infinity
                        : nil,
                    alignment: .leading
                )
            }

            Stepper(
                AppLocalization.format(
                    "Start at %lld",
                    startNumber
                ),
                value: $startNumber,
                in: 1...maximumStartNumber
            )
            .font(.subheadline.monospacedDigit())
        }
    }

    @ViewBuilder
    private var scopePicker: some View {
        let picker = Picker("Page scope", selection: $scope) {
            ForEach(PDFPageBatchScope.allCases) { option in
                Text(option.title.localizedUI)
                    .tag(option)
            }
        }
        if dynamicTypeSize.ppPrefersExpandedLayout {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var formatPicker: some View {
        let picker = Picker("Number format", selection: $format) {
            ForEach(PDFPageNumberFormat.allCases) { option in
                Text(option.title.localizedUI)
                    .tag(option)
            }
        }
        if dynamicTypeSize.ppPrefersExpandedLayout {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var applyBar: some View {
        Button {
            apply()
        } label: {
            HStack(spacing: PPSpacing.small) {
                if isApplying {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "number.square")
                }
                Text(
                    isApplying
                        ? "Applying page numbers".localizedUI
                        : AppLocalization.format(
                            "Number %lld pages",
                            selectedPageCount
                        )
                )
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !isApplying {
                    Image(systemName: "arrow.right")
                }
            }
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(
            isApplying
                || didCommitUpdate
                || selectedPageCount == 0
                || selectedPageCount > 10_000
        )
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.6)
        }
        .accessibilityHint(
            (
                pageNumberingDisabledReason
                    ?? "Adds editable page numbers to the selected pages."
            ).localizedUI
        )
    }

    private var selectedPageIndices: [Int] {
        scope.pageIndices(
            pageCount: pageCount,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
    }

    private var selectedPageCount: Int {
        scope.selectionCount(
            pageCount: pageCount,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
    }

    private var maximumStartNumber: Int {
        max(1, 999_999 - max(0, selectedPageCount - 1))
    }

    private var pageNumberingDisabledReason: String? {
        if isApplying {
            return "Wait for the current operation to finish."
        }
        if selectedPageCount == 0 {
            return "Choose at least one page."
        }
        if selectedPageCount > 10_000 {
            return "Choose no more than 10,000 pages."
        }
        return nil
    }

    private var previewText: String {
        format.text(
            number: startNumber,
            total: startNumber
                + max(0, selectedPageCount - 1)
        )
    }

    private var previewAlignment: Alignment {
        switch position {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    private func apply() {
        guard operationTask == nil, !didCommitUpdate,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        let payload = PDFPageNumberingPayload(
            pageIndices: selectedPageIndices,
            startNumber: startNumber,
            format: format,
            position: position
        )
        isApplying = true
        operationStopRequested = false
        didCommitUpdate = false
        let generation = UUID()
        operationGeneration = generation
        operationTask = Task {
            let succeeded = await onApply(payload)
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            didCommitUpdate = succeeded
            isApplying = false
            operationTask = nil
            operationStopRequested = false
            if wasStopped {
                didCommitUpdate = succeeded
                reportStoppedDocumentUpdate(succeeded: succeeded)
                return
            }
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }

    private func removeAll() {
        guard operationTask == nil, !didCommitUpdate,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        isApplying = true
        operationStopRequested = false
        didCommitUpdate = false
        let generation = UUID()
        operationGeneration = generation
        operationTask = Task {
            let succeeded = await onRemoveAll()
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            didCommitUpdate = succeeded
            isApplying = false
            operationTask = nil
            operationStopRequested = false
            if wasStopped {
                didCommitUpdate = succeeded
                reportStoppedDocumentUpdate(succeeded: succeeded)
                return
            }
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }

    private func interruptOperation(
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

    private func reportStoppedDocumentUpdate(succeeded: Bool) {
        model[noticeFor: paperPathSceneID] = (
            succeeded
                ? "Document update finished before stopping · changes kept"
                : "Document update stopped · working copy unchanged"
        ).localizedUI
    }
}

struct BatesNumberingSheet: View {
    private enum FocusedField: Hashable {
        case leadingAffix
        case trailingAffix
        case startNumber
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let pageCount: Int
    let onApply: (PDFBatesNumberingPayload) async -> Bool
    let onRemoveAll: () async -> Bool

    @State private var scope = PDFPageBatchScope.all
    @State private var position = PDFPageNumberPosition.bottomRight
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var digitCount = 6
    @State private var startNumberText = "1"
    @State private var rangeStart = 1
    @State private var rangeEnd: Int
    @State private var isApplying = false
    @State private var isConfirmingRemoval = false
    @State private var successFeedback = 0
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var operationStopRequested = false
    @State private var didCommitUpdate = false
    @FocusState private var focusedField: FocusedField?

    init(
        pageCount: Int,
        onApply: @escaping (
            PDFBatesNumberingPayload
        ) async -> Bool,
        onRemoveAll: @escaping () async -> Bool
    ) {
        self.pageCount = max(1, pageCount)
        self.onApply = onApply
        self.onRemoveAll = onRemoveAll
        _rangeEnd = State(initialValue: max(1, pageCount))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.large
                ) {
                    WorkflowCommandHeader(
                        eyebrow: "BATES NUMBERING",
                        title: "Assign page IDs",
                        symbol: "number.square.fill",
                        tint: PPColor.amber,
                        metrics: [
                            WorkflowMetric(
                                value: "\(selectedPageCount)",
                                label: "Pages",
                                symbol: "doc.on.doc",
                                tint: PPColor.accent
                            ),
                            WorkflowMetric(
                                value: sequenceSummary,
                                label: "Sequence",
                                symbol: "number",
                                tint: PPColor.amber
                            ),
                            WorkflowMetric(
                                value: position.title,
                                label: "Position",
                                symbol: position.symbol,
                                tint: PPColor.mint
                            )
                        ]
                    )

                    batesPreview
                    scopeControls
                        .disabled(isApplying || didCommitUpdate)
                    sequenceControls
                        .disabled(isApplying || didCommitUpdate)
                }
                .frame(maxWidth: 760)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background(PPCanvas())
            .navigationTitle("Bates Numbering")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationStopRequested
                                ? "Stopping"
                                : isApplying
                                    ? "Stop"
                                    : didCommitUpdate
                                        ? "Done"
                                        : "Cancel"
                        ).localizedUI
                    ) {
                        if isApplying {
                            interruptOperation()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(operationStopRequested)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            isConfirmingRemoval = true
                        } label: {
                            Label(
                                "Remove Bates Numbers",
                                systemImage: "number.square.fill"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isApplying || didCommitUpdate)
                    .accessibilityLabel("Bates number options")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                applyBar
            }
        }
        .interactiveDismissDisabled(isApplying)
        .accessibilityAction(.escape) {
            if isApplying {
                interruptOperation()
            } else {
                dismiss()
            }
        }
        .confirmationDialog(
            "Remove all PaperPath Bates numbers?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(
                "Remove Bates Numbers",
                role: .destructive
            ) {
                removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Page numbers, watermarks, and other annotations are not changed."
            )
        }
        .sensoryFeedback(.success, trigger: successFeedback)
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
            if value != bounded {
                startNumberText = bounded
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            focusedField = nil
            interruptOperation(invalidateResult: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            focusedField = nil
            interruptOperation(invalidateResult: true)
        }
        .onDisappear {
            focusedField = nil
            interruptOperation(invalidateResult: true)
        }
    }

    private var batesPreview: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "PREVIEW")
            ZStack(alignment: previewAlignment) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(PPColor.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(
                                PPColor.border.opacity(0.75),
                                lineWidth: 0.7
                            )
                    }
                    .aspectRatio(0.72, contentMode: .fit)
                    .frame(maxHeight: 250)
                    .shadow(
                        color: .black.opacity(0.1),
                        radius: 4,
                        y: 2
                    )

                Text(firstPreview)
                    .font(
                        .caption.monospacedDigit().weight(.semibold)
                    )
                    .foregroundStyle(
                        PPColor.textPrimary.opacity(0.84)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AppLocalization.format(
                    "Bates preview from %@ to %@",
                    firstPreview,
                    lastPreview
                )
            )
        }
    }

    private var scopeControls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "PAGES")
            scopePicker

            if scope == .range {
                let layout = dynamicTypeSize.ppPrefersExpandedLayout
                    ? AnyLayout(
                        VStackLayout(spacing: PPSpacing.small)
                    )
                    : AnyLayout(
                        HStackLayout(spacing: PPSpacing.small)
                    )
                layout {
                    Stepper(
                        AppLocalization.format(
                            "First page %lld",
                            rangeStart
                        ),
                        value: $rangeStart,
                        in: 1...max(1, rangeEnd)
                    )
                    Stepper(
                        AppLocalization.format(
                            "Last page %lld",
                            rangeEnd
                        ),
                        value: $rangeEnd,
                        in: min(rangeStart, pageCount)...pageCount
                    )
                }
                .font(.subheadline.monospacedDigit())
            }

            if selectedPageCount > 10_000 {
                Label(
                    "Choose no more than 10,000 pages.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
            }
        }
        .padding(.bottom, PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var sequenceControls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "SEQUENCE")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    affixField(
                        title: "Prefix",
                        placeholder: "CASE-",
                        text: $prefix,
                        field: .leadingAffix
                    )
                    affixField(
                        title: "Suffix",
                        placeholder: "-A",
                        text: $suffix,
                        field: .trailingAffix
                    )
                }
                VStack(spacing: PPSpacing.small) {
                    affixField(
                        title: "Prefix",
                        placeholder: "CASE-",
                        text: $prefix,
                        field: .leadingAffix
                    )
                    affixField(
                        title: "Suffix",
                        placeholder: "-A",
                        text: $suffix,
                        field: .trailingAffix
                    )
                }
            }

            TextField(
                "Starting number",
                text: $startNumberText
            )
            .keyboardType(.numberPad)
            .focused($focusedField, equals: .startNumber)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()

            Stepper(
                AppLocalization.format(
                    "Number of digits %lld",
                    digitCount
                ),
                value: $digitCount,
                in: 3...15
            )
            .font(.subheadline.monospacedDigit())

            let positionLayout = dynamicTypeSize.ppPrefersExpandedLayout
                ? AnyLayout(
                    VStackLayout(
                        alignment: .leading,
                        spacing: PPSpacing.xSmall
                    )
                )
                : AnyLayout(
                    HStackLayout(spacing: PPSpacing.medium)
                )
            positionLayout {
                Label("Position", systemImage: position.symbol)
                    .font(.subheadline.weight(.semibold))
                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer(minLength: 0)
                }
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
                .frame(
                    maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                        ? .infinity
                        : nil,
                    alignment: .leading
                )
            }

            if let validationMessage {
                Label(
                    validationMessage.localizedUI,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
            }
        }
    }

    private func affixField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        field: FocusedField
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
                .accessibilityValue(
                    AppLocalization.format(
                        "%lld of 24 characters",
                        text.wrappedValue.count
                    )
                )
        }
    }

    @ViewBuilder
    private var scopePicker: some View {
        let picker = Picker("Page scope", selection: $scope) {
            ForEach(PDFPageBatchScope.allCases) { option in
                Text(option.title.localizedUI)
                    .tag(option)
            }
        }
        if dynamicTypeSize.ppPrefersExpandedLayout {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var applyBar: some View {
        Button {
            apply()
        } label: {
            HStack(spacing: PPSpacing.small) {
                if isApplying {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "number.square.fill")
                }
                Text(
                    isApplying
                        ? "Applying Bates numbers".localizedUI
                        : AppLocalization.format(
                            "Bates number %lld pages",
                            selectedPageCount
                        )
                )
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !isApplying {
                    Image(systemName: "arrow.right")
                }
            }
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(
            isApplying
                || didCommitUpdate
                || validationMessage != nil
                || selectedPageCount == 0
                || selectedPageCount > 10_000
        )
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.6)
        }
        .accessibilityHint(
            (
                applyDisabledReason
                    ?? "Adds one editable Bates identifier to every selected page."
            ).localizedUI
        )
        .accessibilityIdentifier("batesApplyAction")
    }

    private var selectedPageIndices: [Int] {
        scope.pageIndices(
            pageCount: pageCount,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
    }

    private var selectedPageCount: Int {
        scope.selectionCount(
            pageCount: pageCount,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
    }

    private var startNumber: Int64? {
        Int64(startNumberText)
    }

    private var normalizedPrefix: String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSuffix: String {
        suffix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var maximumNumber: Int64 {
        PDFBatesNumberingPayload.maximumNumber(
            digitCount: digitCount
        )
    }

    private var lastNumber: Int64? {
        guard let startNumber,
              selectedPageCount > 0
        else { return nil }
        let offset = Int64(selectedPageCount - 1)
        guard startNumber <= maximumNumber - offset else {
            return nil
        }
        return startNumber + offset
    }

    private var validationMessage: String? {
        guard normalizedPrefix.count <= 24,
              normalizedSuffix.count <= 24
        else {
            return "Use 24 characters or fewer for prefix and suffix."
        }
        guard !prefix.contains("#"), !suffix.contains("#"),
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
        guard lastNumber != nil else {
            return "Increase the digit count for this sequence."
        }
        return nil
    }

    private var applyDisabledReason: String? {
        if isApplying {
            return "Wait for the current operation to finish."
        }
        if let validationMessage {
            return validationMessage
        }
        if selectedPageCount == 0 {
            return "Choose at least one page."
        }
        if selectedPageCount > 10_000 {
            return "Choose no more than 10,000 pages."
        }
        return nil
    }

    private var firstPreview: String {
        PDFBatesNumberingPayload.text(
            number: startNumber ?? 1,
            digitCount: digitCount,
            prefix: normalizedPrefix,
            suffix: normalizedSuffix
        )
    }

    private var lastPreview: String {
        PDFBatesNumberingPayload.text(
            number: lastNumber ?? (startNumber ?? 1),
            digitCount: digitCount,
            prefix: normalizedPrefix,
            suffix: normalizedSuffix
        )
    }

    private var sequenceSummary: String {
        selectedPageCount <= 1
            ? firstPreview
            : "\(firstPreview)–\(lastPreview)"
    }

    private var previewAlignment: Alignment {
        switch position {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    private func apply() {
        guard let startNumber,
              validationMessage == nil,
              operationTask == nil, !didCommitUpdate,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        let payload = PDFBatesNumberingPayload(
            pageIndices: selectedPageIndices,
            startNumber: startNumber,
            digitCount: digitCount,
            prefix: normalizedPrefix,
            suffix: normalizedSuffix,
            position: position
        )
        isApplying = true
        operationStopRequested = false
        didCommitUpdate = false
        let generation = UUID()
        operationGeneration = generation
        operationTask = Task {
            let succeeded = await onApply(payload)
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            didCommitUpdate = succeeded
            isApplying = false
            operationTask = nil
            operationStopRequested = false
            if wasStopped {
                didCommitUpdate = succeeded
                reportStoppedDocumentUpdate(succeeded: succeeded)
                return
            }
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }

    private func removeAll() {
        guard operationTask == nil, !didCommitUpdate,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        isApplying = true
        operationStopRequested = false
        didCommitUpdate = false
        let generation = UUID()
        operationGeneration = generation
        operationTask = Task {
            let succeeded = await onRemoveAll()
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            didCommitUpdate = succeeded
            isApplying = false
            operationTask = nil
            operationStopRequested = false
            if wasStopped {
                didCommitUpdate = succeeded
                reportStoppedDocumentUpdate(succeeded: succeeded)
                return
            }
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }

    private func interruptOperation(
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

    private func reportStoppedDocumentUpdate(succeeded: Bool) {
        model[noticeFor: paperPathSceneID] = (
            succeeded
                ? "Document update finished before stopping · changes kept"
                : "Document update stopped · working copy unchanged"
        ).localizedUI
    }
}

struct WatermarkSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let pageCount: Int
    let onApply: (PDFWatermarkPayload) async -> Bool
    let onRemoveAll: () async -> Bool

    @State private var preset = PDFWatermarkPreset.confidential
    @State private var customText = ""
    @State private var scope = PDFPageBatchScope.all
    @State private var layout = PDFWatermarkLayout.diagonal
    @State private var tone = PDFWatermarkTone.red
    @State private var intensity = PDFWatermarkIntensity.standard
    @State private var rangeStart = 1
    @State private var rangeEnd: Int
    @State private var isApplying = false
    @State private var isConfirmingRemoval = false
    @State private var successFeedback = 0
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var operationStopRequested = false
    @State private var didCommitUpdate = false

    init(
        pageCount: Int,
        onApply: @escaping (PDFWatermarkPayload) async -> Bool,
        onRemoveAll: @escaping () async -> Bool
    ) {
        self.pageCount = max(1, pageCount)
        self.onApply = onApply
        self.onRemoveAll = onRemoveAll
        _rangeEnd = State(initialValue: max(1, pageCount))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.large
                ) {
                    WorkflowCommandHeader(
                        eyebrow: "WATERMARK WORKFLOW",
                        title: "Mark document pages",
                        symbol: "textformat.alt",
                        tint: watermarkTint,
                        metrics: [
                            WorkflowMetric(
                                value: "\(selectedPageCount)",
                                label: "Pages",
                                symbol: "doc.on.doc",
                                tint: PPColor.accent
                            ),
                            WorkflowMetric(
                                value: layout.title,
                                label: "Layout",
                                symbol: layout.symbol,
                                tint: PPColor.cyan
                            ),
                            WorkflowMetric(
                                value: intensity.title,
                                label: "Strength",
                                symbol: "circle.lefthalf.filled",
                                tint: watermarkTint
                            )
                        ]
                    )

                    watermarkPreview
                    textControls
                        .disabled(isApplying || didCommitUpdate)
                    scopeControls
                        .disabled(isApplying || didCommitUpdate)
                    appearanceControls
                        .disabled(isApplying || didCommitUpdate)
                }
                .frame(maxWidth: 760)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background(PPCanvas())
            .navigationTitle("Watermark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationStopRequested
                                ? "Stopping"
                                : isApplying
                                    ? "Stop"
                                    : didCommitUpdate
                                        ? "Done"
                                        : "Cancel"
                        ).localizedUI
                    ) {
                        if isApplying {
                            interruptOperation()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(operationStopRequested)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            isConfirmingRemoval = true
                        } label: {
                            Label(
                                "Remove Generated Watermarks",
                                systemImage: "textformat.alt"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isApplying || didCommitUpdate)
                    .accessibilityLabel("Watermark options")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                applyBar
            }
        }
        .interactiveDismissDisabled(isApplying)
        .accessibilityAction(.escape) {
            if isApplying {
                interruptOperation()
            } else {
                dismiss()
            }
        }
        .confirmationDialog(
            "Remove all PaperPath watermarks?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(
                "Remove Generated Watermarks",
                role: .destructive
            ) {
                removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Page numbers and other annotations are not changed.")
        }
        .sensoryFeedback(.success, trigger: successFeedback)
        .onChange(of: customText) { _, value in
            if value.count > 64 {
                customText = String(value.prefix(64))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptOperation(invalidateResult: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptOperation(invalidateResult: true)
        }
        .onDisappear {
            interruptOperation(invalidateResult: true)
        }
    }

    private var watermarkPreview: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "PREVIEW")
            ZStack(alignment: previewAlignment) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(PPColor.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(
                                PPColor.border.opacity(0.75),
                                lineWidth: 0.7
                            )
                    }
                    .aspectRatio(0.72, contentMode: .fit)
                    .frame(maxHeight: 250)
                    .shadow(
                        color: .black.opacity(0.1),
                        radius: 4,
                        y: 2
                    )

                Text(
                    watermarkText.isEmpty
                        ? "WATERMARK".localizedUI
                        : watermarkText
                )
                .font(
                    layout == .header || layout == .footer
                        ? .caption.weight(.bold)
                        : .title3.weight(.bold)
                )
                .fontDesign(.rounded)
                .foregroundStyle(
                    watermarkTint.opacity(intensity.opacity)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .rotationEffect(
                    layout == .diagonal
                        ? .degrees(-45)
                        : .zero
                )
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AppLocalization.format(
                    "Preview: %@, %@, %@",
                    watermarkText,
                    layout.title.localizedUI,
                    intensity.title.localizedUI
                )
            )
        }
    }

    private var textControls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "TEXT")
            let presetLayout = dynamicTypeSize.ppPrefersExpandedLayout
                ? AnyLayout(
                    VStackLayout(
                        alignment: .leading,
                        spacing: PPSpacing.xSmall
                    )
                )
                : AnyLayout(
                    HStackLayout(spacing: PPSpacing.medium)
                )
            presetLayout {
                Label("Preset", systemImage: "textformat")
                    .font(.subheadline.weight(.semibold))
                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer(minLength: 0)
                }
                Picker("Preset", selection: $preset) {
                    ForEach(PDFWatermarkPreset.allCases) { option in
                        Text(option.title.localizedUI)
                            .tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(
                    maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                        ? .infinity
                        : nil,
                    alignment: .leading
                )
            }

            if preset == .custom {
                TextField(
                    "Watermark text",
                    text: $customText
                )
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .accessibilityValue(
                    AppLocalization.format(
                        "%lld of 64 characters",
                        customText.count
                    )
                )
                .accessibilityIdentifier("watermarkCustomText")
            }

            if let textValidationMessage {
                Label(
                    textValidationMessage.localizedUI,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var scopeControls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "PAGES")
            scopePicker

            if scope == .range {
                let layout = dynamicTypeSize.ppPrefersExpandedLayout
                    ? AnyLayout(
                        VStackLayout(spacing: PPSpacing.small)
                    )
                    : AnyLayout(
                        HStackLayout(spacing: PPSpacing.small)
                    )
                layout {
                    Stepper(
                        AppLocalization.format(
                            "First page %lld",
                            rangeStart
                        ),
                        value: $rangeStart,
                        in: 1...max(1, rangeEnd)
                    )
                    Stepper(
                        AppLocalization.format(
                            "Last page %lld",
                            rangeEnd
                        ),
                        value: $rangeEnd,
                        in: min(rangeStart, pageCount)...pageCount
                    )
                }
                .font(.subheadline.monospacedDigit())
            }

            if selectedPageCount > 10_000 {
                Label(
                    "Choose no more than 10,000 pages.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
            }
        }
        .padding(.bottom, PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "APPEARANCE")

            let layoutPickerLayout =
                dynamicTypeSize.ppPrefersExpandedLayout
                    ? AnyLayout(
                        VStackLayout(
                            alignment: .leading,
                            spacing: PPSpacing.xSmall
                        )
                    )
                    : AnyLayout(
                        HStackLayout(spacing: PPSpacing.medium)
                    )
            layoutPickerLayout {
                Label("Layout", systemImage: layout.symbol)
                    .font(.subheadline.weight(.semibold))
                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer(minLength: 0)
                }
                Picker("Layout", selection: $layout) {
                    ForEach(PDFWatermarkLayout.allCases) { option in
                        Label(
                            option.title.localizedUI,
                            systemImage: option.symbol
                        )
                        .tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(
                    maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                        ? .infinity
                        : nil,
                    alignment: .leading
                )
            }

            let colorLayout = dynamicTypeSize.ppPrefersExpandedLayout
                ? AnyLayout(
                    VStackLayout(
                        alignment: .leading,
                        spacing: PPSpacing.xSmall
                    )
                )
                : AnyLayout(
                    HStackLayout(spacing: PPSpacing.small)
                )
            colorLayout {
                Text("Color")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: PPSpacing.small) {
                    if !dynamicTypeSize.ppPrefersExpandedLayout {
                        Spacer(minLength: 0)
                    }
                    ForEach(PDFWatermarkTone.allCases) { option in
                        Button {
                            tone = option
                        } label: {
                            Circle()
                                .fill(tint(for: option))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if tone == option {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
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
                                "%@ watermark color",
                                option.title.localizedUI
                            )
                        )
                        .accessibilityValue(
                            tone == option ? "Selected" : ""
                        )
                        .accessibilityAddTraits(
                            tone == option ? .isSelected : []
                        )
                    }
                }
            }

            intensityPicker
        }
    }

    @ViewBuilder
    private var scopePicker: some View {
        let picker = Picker("Page scope", selection: $scope) {
            ForEach(PDFPageBatchScope.allCases) { option in
                Text(option.title.localizedUI)
                    .tag(option)
            }
        }
        if dynamicTypeSize.ppPrefersExpandedLayout {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var intensityPicker: some View {
        let picker = Picker(
            "Watermark strength",
            selection: $intensity
        ) {
            ForEach(PDFWatermarkIntensity.allCases) { option in
                Text(option.title.localizedUI)
                    .tag(option)
            }
        }
        if dynamicTypeSize.ppPrefersExpandedLayout {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var applyBar: some View {
        Button {
            apply()
        } label: {
            HStack(spacing: PPSpacing.small) {
                if isApplying {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "textformat.alt")
                }
                Text(
                    isApplying
                        ? "Applying watermark".localizedUI
                        : AppLocalization.format(
                            "Watermark %lld pages",
                            selectedPageCount
                        )
                )
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !isApplying {
                    Image(systemName: "arrow.right")
                }
            }
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(
            isApplying
                || didCommitUpdate
                || textValidationMessage != nil
                || selectedPageCount == 0
                || selectedPageCount > 10_000
        )
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.6)
        }
        .accessibilityHint(
            (
                watermarkApplyDisabledReason
                    ?? "Adds one editable watermark to every selected page."
            ).localizedUI
        )
        .accessibilityIdentifier("watermarkApplyAction")
    }

    private var selectedPageIndices: [Int] {
        scope.pageIndices(
            pageCount: pageCount,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
    }

    private var selectedPageCount: Int {
        scope.selectionCount(
            pageCount: pageCount,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
    }

    private var watermarkText: String {
        let value = preset == .custom
            ? customText
            : preset.defaultText.localizedUI
        return value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private var isTextValid: Bool {
        textValidationMessage == nil
    }

    private var textValidationMessage: String? {
        guard !watermarkText.isEmpty else {
            return "Enter watermark text."
        }
        guard watermarkText.count <= 64 else {
            return "Use 64 characters or fewer for watermark text."
        }
        guard preset != .custom
                || customText.rangeOfCharacter(
                    from: .controlCharacters
                ) == nil
        else {
            return "Watermark text cannot contain line breaks."
        }
        return nil
    }

    private var watermarkApplyDisabledReason: String? {
        if isApplying {
            return "Wait for the current operation to finish."
        }
        if let textValidationMessage {
            return textValidationMessage
        }
        if selectedPageCount == 0 {
            return "Choose at least one page."
        }
        if selectedPageCount > 10_000 {
            return "Choose no more than 10,000 pages."
        }
        return nil
    }

    private var previewAlignment: Alignment {
        switch layout {
        case .diagonal, .centered: return .center
        case .header: return .top
        case .footer: return .bottom
        }
    }

    private var watermarkTint: Color {
        tint(for: tone)
    }

    private func tint(for tone: PDFWatermarkTone) -> Color {
        switch tone {
        case .red: return .red
        case .graphite: return PPColor.textPrimary
        case .blue: return PPColor.accent
        }
    }

    private func apply() {
        guard isTextValid,
              operationTask == nil, !didCommitUpdate,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        isApplying = true
        operationStopRequested = false
        didCommitUpdate = false
        let payload = PDFWatermarkPayload(
            pageIndices: selectedPageIndices,
            text: watermarkText,
            layout: layout,
            tone: tone,
            intensity: intensity
        )
        let generation = UUID()
        operationGeneration = generation
        operationTask = Task {
            let succeeded = await onApply(payload)
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            didCommitUpdate = succeeded
            isApplying = false
            operationTask = nil
            operationStopRequested = false
            if wasStopped {
                didCommitUpdate = succeeded
                reportStoppedDocumentUpdate(succeeded: succeeded)
                return
            }
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }

    private func removeAll() {
        guard operationTask == nil, !didCommitUpdate,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        isApplying = true
        operationStopRequested = false
        didCommitUpdate = false
        let generation = UUID()
        operationGeneration = generation
        operationTask = Task {
            let succeeded = await onRemoveAll()
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            didCommitUpdate = succeeded
            isApplying = false
            operationTask = nil
            operationStopRequested = false
            if wasStopped {
                didCommitUpdate = succeeded
                reportStoppedDocumentUpdate(succeeded: succeeded)
                return
            }
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }

    private func interruptOperation(
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

    private func reportStoppedDocumentUpdate(succeeded: Bool) {
        model[noticeFor: paperPathSceneID] = (
            succeeded
                ? "Document update finished before stopping · changes kept"
                : "Document update stopped · working copy unchanged"
        ).localizedUI
    }
}

struct NoteComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let pageIndex: Int
    let onAdd: (String) -> Void

    @State private var note = ""
    @State private var isConfirmingDiscard = false
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: PPSpacing.large) {
                HStack {
                    Text(AppLocalization.format("Page %lld", pageIndex + 1))
                    Spacer()
                    Text("\(note.count)/1000")
                        .monospacedDigit()
                        .foregroundStyle(note.count > 900 ? PPColor.amber : PPColor.textSecondary)
                }
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)

                VStack(alignment: .trailing, spacing: PPSpacing.small) {
                    TextField(
                        "Note",
                        text: $note,
                        axis: .vertical
                    )
                    .focused($isNoteFocused)
                    .lineLimit(5...12)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .onSubmit(submitNote)
                    .accessibilityIdentifier("noteText")
                    .padding(PPSpacing.medium)
                    .background(PPColor.surface)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(PPColor.amber.opacity(0.55))
                            .frame(height: 1)
                    }

                    PasteButton(payloadType: String.self) { values in
                        paste(values.first)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint(
                        "Pastes text into the note"
                    )
                    .accessibilityIdentifier("notePasteAction")
                }
            }
            .padding(PPSpacing.regular)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("noteComposerContent")
            .background(PPCanvas())
            .navigationTitle("Add note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        requestDismissal()
                    }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: submitNote)
                        .disabled(trimmedNote.isEmpty)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("noteAddAction")
                }
            }
            .onChange(of: note) { _, value in
                if value.count > 1_000 {
                    note = String(value.prefix(1_000))
                }
            }
            .confirmationDialog(
                "Discard note draft?".localizedUI,
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button(
                    "Discard Draft".localizedUI,
                    role: .destructive
                ) {
                    dismiss()
                }
                Button("Keep Editing".localizedUI, role: .cancel) {}
            } message: {
                Text(
                    "The note has not been added to the PDF."
                        .localizedUI
                )
            }
            .interactiveDismissDisabled(!trimmedNote.isEmpty)
            .accessibilityAction(.escape) {
                requestDismissal()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                discardProtectedDraft()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                discardProtectedDraft()
            }
            .onDisappear {
                note = ""
                isNoteFocused = false
            }
            .task {
                await Task.yield()
                isNoteFocused = true
            }
        }
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitNote() {
        guard !trimmedNote.isEmpty else { return }
        isNoteFocused = false
        onAdd(trimmedNote)
    }

    private func paste(_ value: String?) {
        guard let value else { return }
        let separator = note.isEmpty ? "" : "\n"
        note = String((note + separator + value).prefix(1_000))
        isNoteFocused = true
    }

    private func requestDismissal() {
        if trimmedNote.isEmpty {
            dismiss()
        } else {
            isConfirmingDiscard = true
        }
    }

    private func discardProtectedDraft() {
        note = ""
        isNoteFocused = false
        dismiss()
    }
}
