import SwiftUI

struct StampPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let pageIndex: Int
    let onSelect: (PDFStampKind) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PPSpacing.large) {
                    WorkflowCommandHeader(
                        eyebrow: "STAMP WORKFLOW",
                        title: "Stamp page \(pageIndex + 1)",
                        detail: "Standard PDF stamps stay editable and appear in annotation review.",
                        symbol: "seal",
                        tint: PPColor.amber,
                        metrics: [
                            WorkflowMetric(
                                value: "\(PDFStampKind.allCases.count)",
                                label: "Marks",
                                symbol: "seal",
                                tint: PPColor.amber
                            ),
                            WorkflowMetric(
                                value: "\(pageIndex + 1)",
                                label: "Page",
                                symbol: "doc.text",
                                tint: PPColor.accent
                            ),
                            WorkflowMetric(
                                value: "Editable",
                                label: "Result",
                                symbol: "pencil",
                                tint: PPColor.mint
                            )
                        ]
                    )

                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(
                                    minimum: 210,
                                    maximum: 320
                                ),
                                spacing: PPSpacing.small
                            )
                        ],
                        spacing: PPSpacing.small
                    ) {
                        ForEach(PDFStampKind.allCases) { kind in
                            Button {
                                dismiss()
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
                                "Adds \(kind.title.lowercased()) to page \(pageIndex + 1)"
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
                }
            }
        }
    }

    private func stampPreview(_ kind: PDFStampKind) -> some View {
        Text(kind.title.localizedUI.uppercased())
            .font(.caption2.smallCaps().weight(.bold))
            .fontDesign(.monospaced)
            .foregroundStyle(tint(for: kind))
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                        detail: "Editable PDF text · removable before delivery",
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
                    numberingControls
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
                        (isApplying ? "Stop" : "Cancel").localizedUI
                    ) {
                        if isApplying {
                            operationTask?.cancel()
                        } else {
                            dismiss()
                        }
                    }
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
                    .disabled(isApplying)
                    .accessibilityLabel("Page number options")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                applyBar
            }
        }
        .interactiveDismissDisabled(isApplying)
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
        .onDisappear {
            operationTask?.cancel()
            operationTask = nil
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
                let layout = dynamicTypeSize.isAccessibilitySize
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
        if dynamicTypeSize.isAccessibilitySize {
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
        if dynamicTypeSize.isAccessibilitySize {
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
                Spacer()
                if !isApplying {
                    Image(systemName: "arrow.right")
                }
            }
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            isApplying
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
            "Adds editable page numbers to the selected pages."
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
        let payload = PDFPageNumberingPayload(
            pageIndices: selectedPageIndices,
            startNumber: startNumber,
            format: format,
            position: position
        )
        isApplying = true
        operationTask = Task {
            let succeeded = await onApply(payload)
            if Task.isCancelled {
                if succeeded {
                    dismiss()
                }
                isApplying = false
                operationTask = nil
                return
            }
            isApplying = false
            operationTask = nil
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }

    private func removeAll() {
        isApplying = true
        operationTask = Task {
            let succeeded = await onRemoveAll()
            if Task.isCancelled {
                if succeeded {
                    dismiss()
                }
                isApplying = false
                operationTask = nil
                return
            }
            isApplying = false
            operationTask = nil
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }
}

struct BatesNumberingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                        detail:
                            "Fixed-width sequence · checked after writing",
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
                    sequenceControls
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
                        (isApplying ? "Stop" : "Cancel").localizedUI
                    ) {
                        if isApplying {
                            operationTask?.cancel()
                        } else {
                            dismiss()
                        }
                    }
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
                    .disabled(isApplying)
                    .accessibilityLabel("Bates number options")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                applyBar
            }
        }
        .interactiveDismissDisabled(isApplying)
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
            if value != bounded {
                startNumberText = bounded
            }
        }
        .onDisappear {
            operationTask?.cancel()
            operationTask = nil
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
                let layout = dynamicTypeSize.isAccessibilitySize
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

            TextField(
                "Starting number",
                text: $startNumberText
            )
            .keyboardType(.numberPad)
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
            }
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

    @ViewBuilder
    private var scopePicker: some View {
        let picker = Picker("Page scope", selection: $scope) {
            ForEach(PDFPageBatchScope.allCases) { option in
                Text(option.title.localizedUI)
                    .tag(option)
            }
        }
        if dynamicTypeSize.isAccessibilitySize {
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
                Spacer()
                if !isApplying {
                    Image(systemName: "arrow.right")
                }
            }
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            isApplying
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
            "Adds one editable Bates identifier to every selected page."
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
              validationMessage == nil
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
        operationTask = Task {
            let succeeded = await onApply(payload)
            if Task.isCancelled {
                if succeeded {
                    dismiss()
                }
                isApplying = false
                operationTask = nil
                return
            }
            isApplying = false
            operationTask = nil
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }

    private func removeAll() {
        isApplying = true
        operationTask = Task {
            let succeeded = await onRemoveAll()
            if Task.isCancelled {
                if succeeded {
                    dismiss()
                }
                isApplying = false
                operationTask = nil
                return
            }
            isApplying = false
            operationTask = nil
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }
}

struct WatermarkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                        detail:
                            "Editable PDF text · checked after writing",
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
                    scopeControls
                    appearanceControls
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
                        (isApplying ? "Stop" : "Cancel").localizedUI
                    ) {
                        if isApplying {
                            operationTask?.cancel()
                        } else {
                            dismiss()
                        }
                    }
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
                    .disabled(isApplying)
                    .accessibilityLabel("Watermark options")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                applyBar
            }
        }
        .interactiveDismissDisabled(isApplying)
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
        .onDisappear {
            operationTask?.cancel()
            operationTask = nil
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
            HStack(spacing: PPSpacing.medium) {
                Label("Preset", systemImage: "textformat")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Preset", selection: $preset) {
                    ForEach(PDFWatermarkPreset.allCases) { option in
                        Text(option.title.localizedUI)
                            .tag(option)
                    }
                }
                .pickerStyle(.menu)
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
                let layout = dynamicTypeSize.isAccessibilitySize
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

            HStack(spacing: PPSpacing.medium) {
                Label("Layout", systemImage: layout.symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
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
            }

            HStack(spacing: PPSpacing.small) {
                Text("Color")
                    .font(.subheadline.weight(.semibold))
                Spacer()
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
        if dynamicTypeSize.isAccessibilitySize {
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
        if dynamicTypeSize.isAccessibilitySize {
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
                Spacer()
                if !isApplying {
                    Image(systemName: "arrow.right")
                }
            }
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            isApplying
                || !isTextValid
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
            "Adds one editable watermark to every selected page."
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

    private var watermarkText: String {
        let value = preset == .custom
            ? customText
            : preset.defaultText.localizedUI
        return value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private var isTextValid: Bool {
        !watermarkText.isEmpty
            && watermarkText.count <= 64
            && watermarkText.rangeOfCharacter(
                from: .controlCharacters
            ) == nil
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
        guard isTextValid else { return }
        isApplying = true
        let payload = PDFWatermarkPayload(
            pageIndices: selectedPageIndices,
            text: watermarkText,
            layout: layout,
            tone: tone,
            intensity: intensity
        )
        operationTask = Task {
            let succeeded = await onApply(payload)
            if Task.isCancelled {
                if succeeded {
                    dismiss()
                }
                isApplying = false
                operationTask = nil
                return
            }
            isApplying = false
            operationTask = nil
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }

    private func removeAll() {
        isApplying = true
        operationTask = Task {
            let succeeded = await onRemoveAll()
            if Task.isCancelled {
                if succeeded {
                    dismiss()
                }
                isApplying = false
                operationTask = nil
                return
            }
            isApplying = false
            operationTask = nil
            guard succeeded else { return }
            successFeedback += 1
            dismiss()
        }
    }
}

struct NoteComposerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let pageIndex: Int
    let onAdd: (String) -> Void

    @State private var note = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: PPSpacing.large) {
                WorkflowCommandHeader(
                    eyebrow: "NOTE WORKFLOW",
                    title: "Add note",
                    detail: "The note stays editable and appears in annotation review.",
                    symbol: "note.text.badge.plus",
                    tint: PPColor.amber,
                    metrics: [
                        WorkflowMetric(
                            value: "\(pageIndex + 1)",
                            label: "Page",
                            symbol: "doc.text",
                            tint: PPColor.accent
                        ),
                        WorkflowMetric(
                            value: "\(note.count)/1000",
                            label: "Characters",
                            symbol: "textformat",
                            tint: note.count > 900
                                ? PPColor.amber
                                : PPColor.cyan
                        ),
                        WorkflowMetric(
                            value: "Center",
                            label: "Placement",
                            symbol: "scope",
                            tint: PPColor.mint
                        )
                    ]
                )

                TextField(
                    "Note",
                    text: $note,
                    axis: .vertical
                )
                .lineLimit(5...12)
                .textFieldStyle(.plain)
                .padding(PPSpacing.medium)
                .background(PPColor.surface)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PPColor.amber.opacity(0.55))
                        .frame(height: 1)
                }
                Spacer(minLength: 0)
            }
            .padding(PPSpacing.regular)
            .background(PPCanvas())
            .navigationTitle("Add note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let value = note.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        dismiss()
                        onAdd(value)
                    }
                    .disabled(
                        note.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                }
            }
            .onChange(of: note) { _, value in
                if value.count > 1_000 {
                    note = String(value.prefix(1_000))
                }
            }
        }
    }
}
