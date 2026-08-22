import PDFKit
import SwiftUI

struct FormReviewView: View {
    private enum FieldFilter: String, CaseIterable, Identifiable {
        case all
        case required
        case incomplete
        case complete

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let initialPageIndex: Int
    let onSelectPage: (Int) -> Void
    let onSignField: (PDFFormFieldSnapshot) -> Void
    let onPrepare: () -> Void

    @State private var report = PDFFormInspectionReport.empty
    @State private var isLoading = true
    @State private var isAddingField = false
    @State private var isSharingForCompatibility = false
    @State private var isRefreshingAutomation = false
    @State private var fieldFilter = FieldFilter.all

    init(
        recordID: UUID,
        initialPageIndex: Int = 0,
        onSelectPage: @escaping (Int) -> Void,
        onSignField: @escaping (PDFFormFieldSnapshot) -> Void = { _ in },
        onPrepare: @escaping () -> Void = {}
    ) {
        self.recordID = recordID
        self.initialPageIndex = initialPageIndex
        self.onSelectPage = onSelectPage
        self.onSignField = onSignField
        self.onPrepare = onPrepare
    }

    private var fields: [PDFFormFieldSnapshot] {
        report.fields
    }

    private var incomplete: [PDFFormFieldSnapshot] {
        fields.filter { !$0.isComplete }
    }

    private var orderedFields: [PDFFormFieldSnapshot] {
        filteredFields.sorted {
            if $0.issue != nil && $1.issue == nil { return true }
            if $0.issue == nil && $1.issue != nil { return false }
            if $0.isRequired != $1.isRequired {
                return $0.isRequired
            }
            if $0.isComplete != $1.isComplete {
                return !$0.isComplete
            }
            if $0.pageIndex != $1.pageIndex {
                return $0.pageIndex < $1.pageIndex
            }
            return $0.name < $1.name
        }
    }

    private var filteredFields: [PDFFormFieldSnapshot] {
        switch fieldFilter {
        case .all:
            return fields
        case .required:
            return fields.filter(\.isRequired)
        case .incomplete:
            return fields.filter { !$0.isComplete }
        case .complete:
            return fields.filter(\.isComplete)
        }
    }

    private var completionRatio: Double {
        guard !fields.isEmpty else { return 0 }
        return Double(fields.count - incomplete.count)
            / Double(fields.count)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Checking form fields")
                } else {
                    formContent
                }
            }
            .background(PPColor.canvas)
            .navigationTitle("Form check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isRefreshingAutomation)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingField = true
                    } label: {
                        Label("Add Field", systemImage: "plus")
                    }
                    .disabled(report.hasXFA)
                }
            }
            .task {
                await loadReport()
            }
            .fullScreenCover(isPresented: $isAddingField) {
                PDFFormFieldEditorView(
                    recordID: recordID,
                    initialPageIndex: initialPageIndex,
                    existingFields: fields
                ) {
                    Task { await loadReport() }
                }
            }
            .sheet(isPresented: $isSharingForCompatibility) {
                if let url = model.url(for: recordID) {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private var formContent: some View {
        List {
            Section {
                compatibilitySummary
            }

            if !report.issues.isEmpty {
                Section("Compatibility") {
                    ForEach(
                        Array(report.issues.enumerated()),
                        id: \.offset
                    ) { _, issue in
                        Label(
                            issue,
                            systemImage: report.hasXFA
                                ? "eye"
                                : "exclamationmark.triangle"
                        )
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textSecondary)
                    }
                }
            }

            if !report.automationFields.isEmpty
                || report.unsupportedJavaScriptCount > 0 {
                Section("Form Logic") {
                    ForEach(report.automationFields) {
                        automation in
                        automationRow(automation)
                    }

                    if !report.calculatedFields.isEmpty,
                       report.unsupportedJavaScriptCount == 0 {
                        Button {
                            refreshAutomation()
                        } label: {
                            Label(
                                report.fieldsNeedingAutomationUpdate.isEmpty
                                    ? "Recheck Calculations"
                                    : "Refresh Calculations",
                                systemImage: "function"
                            )
                        }
                        .disabled(
                            isRefreshingAutomation
                                || !report.invalidAutomationFields.isEmpty
                        )
                        .accessibilityIdentifier(
                            "refreshFormCalculations"
                        )
                    }
                }
            }

            if report.requiresCompatibleReader {
                Section("Continue safely") {
                    Button {
                        isSharingForCompatibility = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Open a copy in another app")
                                    .foregroundStyle(PPColor.textPrimary)
                                Text(
                                    "The private working copy keeps the original form data intact."
                                )
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(PPColor.accent)
                        }
                    }
                    .accessibilityIdentifier(
                        "shareFormWithCompatibleReader"
                    )
                }
            }

            if fields.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No interactive fields",
                        systemImage: "list.bullet.clipboard",
                        description: Text(
                            report.hasXFA
                                ? "XFA content is preserved for another compatible reader."
                                : "Add text, checkbox, radio, choice, or signature fields to this working copy."
                        )
                    )
                }
            } else {
                Section {
                    Picker("Field filter", selection: $fieldFilter) {
                        ForEach(FieldFilter.allCases) { filter in
                            Text(filter.title.localizedUI)
                                .tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(
                    report.incompleteRequiredFields.isEmpty
                        ? "Fields"
                        : "Required first"
                ) {
                    ForEach(orderedFields) { field in
                        fieldRow(field)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var compatibilitySummary: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            WorkflowCommandHeader(
                eyebrow: "FORM WORKFLOW",
                title: report.compatibility.title,
                detail: summaryDetail,
                symbol: report.compatibility.symbol,
                tint: compatibilityColor,
                metrics: [
                    WorkflowMetric(
                        value: "\(fields.count)",
                        label: "Fields",
                        symbol: "list.bullet.rectangle",
                        tint: PPColor.accent
                    ),
                    WorkflowMetric(
                        value: "\(report.incompleteRequiredFields.count)",
                        label: "Required",
                        symbol: "exclamationmark.circle",
                        tint: report.incompleteRequiredFields.isEmpty
                            ? PPColor.mint
                            : PPColor.amber
                    ),
                    WorkflowMetric(
                        value: "\(Int(completionRatio * 100))%",
                        label: "Complete",
                        symbol: "chart.bar.fill",
                        tint: PPColor.mint
                    )
                ]
            )

            if !fields.isEmpty {
                ProgressView(value: completionRatio)
                    .tint(
                        report.incompleteRequiredFields.isEmpty
                            ? PPColor.mint
                            : PPColor.accent
                    )
                    .accessibilityLabel("Form completion")
                    .accessibilityValue(
                        "\(Int(completionRatio * 100)) percent"
                    )
            }

            if let next = report.incompleteRequiredFields.first {
                Button {
                    open(next)
                } label: {
                    Label(
                        next.kind == .signature
                            ? "Sign \(next.name)"
                            : "Continue with \(next.name)",
                        systemImage: next.kind == .signature
                            ? "signature"
                            : "arrow.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .accessibilityIdentifier("continueRequiredFormField")
                .accessibilityHint(
                    next.kind == .signature
                        ? "Opens signature placement on page \(next.pageIndex + 1)"
                        : "Opens page \(next.pageIndex + 1)"
                )
            } else if report.isReadyForVerifiedOutput {
                Button {
                    dismiss()
                    onPrepare()
                } label: {
                    Label(
                        "Verify & Share",
                        systemImage: "checkmark.shield"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .accessibilityIdentifier("formVerifyAndShare")
                .accessibilityHint(
                    "Checks the final copy before sharing"
                )
            }
        }
        .padding(.vertical, PPSpacing.xSmall)
    }

    private func fieldRow(
        _ field: PDFFormFieldSnapshot
    ) -> some View {
        Button {
            open(field)
        } label: {
            HStack(spacing: PPSpacing.medium) {
                Image(systemName: field.kind.symbol)
                    .foregroundStyle(
                        field.issue != nil
                            ? PPColor.amber
                            : field.isComplete
                                ? PPColor.mint
                                : PPColor.accent
                    )
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(field.name)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        if field.isRequired {
                            Text("REQUIRED")
                                .font(.caption2.smallCaps().weight(.bold))
                                .foregroundStyle(PPColor.amber)
                        }
                        if field.isReadOnly {
                            Image(systemName: "lock")
                                .font(.caption2)
                                .foregroundStyle(PPColor.textSecondary)
                        }
                    }
                    Text(fieldDetail(field).localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .accessibilityHint(
            isActionableSignature(field)
                ? "Opens signature placement on page \(field.pageIndex + 1)"
                : "Opens page \(field.pageIndex + 1)"
        )
        .accessibilityIdentifier(
            "formField-\(field.pageIndex)-\(field.annotationIndex)"
        )
    }

    private var summaryDetail: String {
        if report.hasXFA {
            return "XFA remains intact, but field editing is left to a compatible reader."
        }
        if fields.isEmpty {
            return "Create fields exactly where recipients should type, check, or sign."
        }
        if !report.invalidAutomationFields.isEmpty {
            let count = report.invalidAutomationFields.count
            return "\(count) value\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") format or range correction"
        }
        if !report.fieldsNeedingAutomationUpdate.isEmpty {
            let count = report.fieldsNeedingAutomationUpdate.count
            return "\(count) calculated field\(count == 1 ? "" : "s") ready to refresh locally"
        }
        if report.unsupportedJavaScriptCount > 0 {
            return "Custom form logic is preserved for a compatible reader."
                .localizedUI
        }
        if report.incompleteRequiredFields.isEmpty {
            let optionalCount = report.incompleteOptionalFields.count
            if optionalCount > 0 {
                return AppLocalization.format(
                    "Required fields complete · %lld optional field%@ left",
                    optionalCount,
                    optionalCount == 1 ? "" : "s"
                )
            }
            return AppLocalization.format(
                "%lld editable · required fields complete",
                report.editableFieldCount
            )
        }
        let count = report.incompleteRequiredFields.count
        return AppLocalization.format(
            "%lld required field%@ still incomplete",
            count,
            count == 1 ? "" : "s"
        )
    }

    private var compatibilityColor: Color {
        switch report.compatibility {
        case .ready: return PPColor.mint
        case .limited: return PPColor.amber
        case .unsupported: return PPColor.textSecondary
        }
    }

    private func fieldDetail(
        _ field: PDFFormFieldSnapshot
    ) -> String {
        if let issue = field.issue {
            return issue.localizedUI
        }
        var parts = [
            field.kind.title.localizedUI,
            AppLocalization.format(
                "Page %lld",
                field.pageIndex + 1
            )
        ]
        if field.optionCount > 0 {
            parts.append(
                AppLocalization.format(
                    "%lld options",
                    field.optionCount
                )
            )
        }
        if field.isMultiline {
            parts.append("multiline".localizedUI)
        }
        if field.isComplete {
            parts.append("complete".localizedUI)
        } else if isActionableSignature(field) {
            parts.append("tap to sign".localizedUI)
        }
        if let automation = report.automation(for: field) {
            if automation.calculation != nil {
                parts.append(
                    automation.needsUpdate
                        ? "calculation pending".localizedUI
                        : "calculated".localizedUI
                )
            } else if let format = automation.format {
                parts.append(
                    AppLocalization.format(
                        "%@ checked",
                        format.kind.title.localizedUI
                    )
                )
            }
        }
        return parts.joined(separator: " · ")
    }

    private func automationRow(
        _ automation: PDFFormAutomationFieldSnapshot
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            Image(
                systemName: automation.validationIssue == nil
                    ? automation.needsUpdate
                        ? "arrow.triangle.2.circlepath"
                        : "checkmark.circle"
                    : "exclamationmark.triangle"
            )
            .foregroundStyle(
                automation.validationIssue == nil
                    ? automation.needsUpdate
                        ? PPColor.accent
                        : PPColor.mint
                    : PPColor.amber
            )
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(automation.fieldName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(automationDetail(automation).localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let preview = automation.formattedPreview {
                    Text("Preview: \(preview)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(2)
                }
                if let issue = automation.validationIssue {
                    Text(issue.localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func automationDetail(
        _ automation: PDFFormAutomationFieldSnapshot
    ) -> String {
        var parts: [String] = []
        if let calculation = automation.calculation {
            parts.append(
                AppLocalization.format(
                    "%@ of %@",
                    calculation.operation.title.localizedUI,
                    calculation.sourceFieldNames.joined(separator: ", ")
                )
            )
        }
        if let format = automation.format {
            if let pattern = format.pattern {
                parts.append(
                    AppLocalization.format(
                        "%@: %@",
                        format.kind.title.localizedUI,
                        pattern
                    )
                )
            } else {
                parts.append(
                    AppLocalization.format(
                        "%@, %lld decimals",
                        format.kind.title.localizedUI,
                        format.decimalPlaces
                    )
                )
            }
        }
        if let range = automation.rangeValidation {
            switch (range.minimum, range.maximum) {
            case let (.some(minimum), .some(maximum)):
                parts.append(
                    AppLocalization.format(
                        "Range %@–%@",
                        minimum.formatted(),
                        maximum.formatted()
                    )
                )
            case let (.some(minimum), .none):
                parts.append(
                    AppLocalization.format(
                        "Minimum %@",
                        minimum.formatted()
                    )
                )
            case let (.none, .some(maximum)):
                parts.append(
                    AppLocalization.format(
                        "Maximum %@",
                        maximum.formatted()
                    )
                )
            case (.none, .none):
                break
            }
        }
        if automation.unsupportedActionCount > 0 {
            parts.append(
                AppLocalization.format(
                    "%lld custom script",
                    automation.unsupportedActionCount
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    private func loadReport() async {
        isLoading = true
        defer { isLoading = false }
        do {
            report = try await model.inspectForm(recordID: recordID)
            let checkpoint: DocumentTaskCheckpoint?
            if let next = report.incompleteRequiredFields.first {
                checkpoint = DocumentTaskCheckpoint(
                    stage: next.kind == .signature ? .sign : .fillForm,
                    pageIndex: next.pageIndex,
                    fieldName: next.name,
                    normalizedBounds: next.kind == .signature
                        ? next.normalizedBounds
                        : nil
                )
            } else if report.isReadyForVerifiedOutput {
                checkpoint = DocumentTaskCheckpoint(stage: .verify)
            } else if report.hasXFA {
                checkpoint = DocumentTaskCheckpoint(stage: .fillForm)
            } else {
                checkpoint = nil
            }
            await model.updateTaskCheckpoint(
                recordID: recordID,
                checkpoint: checkpoint
            )
            if !report.fields.isEmpty {
                await model.setActionCompletion(
                    recordID: recordID,
                    action: .reviewForm,
                    completed: report.incompleteRequiredFields.isEmpty
                        && report.compatibility != .unsupported
                )
            }
        } catch {
            model.present(error)
        }
    }

    private func refreshAutomation() {
        guard !isRefreshingAutomation else { return }
        isRefreshingAutomation = true
        Task {
            let succeeded = await model.refreshFormAutomation(
                recordID: recordID
            )
            if succeeded {
                await loadReport()
            }
            isRefreshingAutomation = false
        }
    }

    private func open(_ field: PDFFormFieldSnapshot) {
        let checkpoint = DocumentTaskCheckpoint(
            stage: isActionableSignature(field) ? .sign : .fillForm,
            pageIndex: field.pageIndex,
            fieldName: field.name,
            normalizedBounds: isActionableSignature(field)
                ? field.normalizedBounds
                : nil
        )
        Task {
            await model.updateTaskCheckpoint(
                recordID: recordID,
                checkpoint: checkpoint
            )
        }
        dismiss()
        if isActionableSignature(field) {
            onSignField(field)
        } else {
            onSelectPage(field.pageIndex)
        }
    }

    private func isActionableSignature(
        _ field: PDFFormFieldSnapshot
    ) -> Bool {
        field.kind == .signature
            && !field.isComplete
            && !field.isReadOnly
            && field.issue == nil
    }
}

private struct PDFFormFieldEditorView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let existingFields: [PDFFormFieldSnapshot]
    let onCreated: () -> Void

    @State private var pageIndex: Int
    @State private var kind: PDFFormFieldKind = .text
    @State private var fieldName = ""
    @State private var isRequired = false
    @State private var isMultiline = false
    @State private var maximumLength = 0
    @State private var optionsText = "Option 1\nOption 2"
    @State private var isListChoice = false
    @State private var bounds: PDFNormalizedRect
    @State private var pagePreview: UIImage?
    @State private var pageAspectRatio: CGFloat = 612 / 792
    @State private var isSaving = false
    @State private var dragStartBounds: PDFNormalizedRect?
    @State private var saveTask: Task<Void, Never>?

    init(
        recordID: UUID,
        initialPageIndex: Int,
        existingFields: [PDFFormFieldSnapshot],
        onCreated: @escaping () -> Void
    ) {
        self.recordID = recordID
        self.existingFields = existingFields
        self.onCreated = onCreated
        let pageIndex = max(0, initialPageIndex)
        _pageIndex = State(initialValue: pageIndex)
        _bounds = State(
            initialValue: Self.suggestedPlacement(
                pageIndex: pageIndex,
                existingFields: existingFields,
                width: 0.42,
                height: 0.07
            )
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                pageStage(availableSize: proxy.size)
            }
            .background(PPColor.canvas)
            .safeAreaInset(edge: .top, spacing: 0) {
                precisionContextBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls
            }
            .navigationTitle("Place Form Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button((isSaving ? "Stop" : "Cancel").localizedUI) {
                        if isSaving {
                            saveTask?.cancel()
                            saveTask = nil
                            isSaving = false
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addField() }
                        .disabled(!canAdd || isSaving)
                        .accessibilityIdentifier("addFormField")
                }
            }
            .task(id: pageIndex) {
                await loadPage()
            }
            .onChange(of: pageIndex) { _, value in
                bounds = Self.suggestedPlacement(
                    pageIndex: value,
                    existingFields: existingFields,
                    width: bounds.width,
                    height: bounds.height
                )
            }
            .onChange(of: kind) { _, value in
                resizeForKind(value)
            }
            .onChange(of: isListChoice) { _, _ in
                guard kind == .choice else { return }
                resizeForKind(kind)
            }
            .onChange(of: optionsText) { _, _ in
                guard kind == .radio else { return }
                resizeForKind(kind)
            }
            .interactiveDismissDisabled(isSaving)
            .onDisappear {
                saveTask?.cancel()
                saveTask = nil
            }
        }
    }

    private var precisionContextBar: some View {
        HStack(spacing: PPSpacing.medium) {
            Label(
                "Page \(pageIndex + 1)",
                systemImage: "doc.text"
            )
            Label(kind.title, systemImage: kind.symbol)
            Label(
                "\(Int(bounds.width * 100))×\(Int(bounds.height * 100))%",
                systemImage: "arrow.up.left.and.arrow.down.right"
            )
            if !overlappingFields.isEmpty {
                Label(
                    AppLocalization.format(
                        "%lld overlap",
                        overlappingFields.count
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(PPColor.amber)
            }
            Spacer(minLength: 0)
            OnDeviceBadge(compact: true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, PPSpacing.regular)
        .frame(minHeight: 38)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func pageStage(
        availableSize: CGSize
    ) -> some View {
        let pageSize = fittedPageSize(in: availableSize)
        return ZStack {
            PPColor.canvas
            ZStack {
                Color.white
                if let pagePreview {
                    Image(uiImage: pagePreview)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
                existingFieldOverlays(pageSize: pageSize)
                placementOverlay(pageSize: pageSize)
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        }
    }

    private func existingFieldOverlays(
        pageSize: CGSize
    ) -> some View {
        ForEach(
            existingFields.filter { $0.pageIndex == pageIndex }
        ) { field in
            let rect = displayRect(
                field.normalizedBounds,
                pageSize: pageSize
            )
            Rectangle()
                .stroke(
                    PPColor.textSecondary.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .accessibilityHidden(true)
        }
    }

    private func placementOverlay(
        pageSize: CGSize
    ) -> some View {
        let rect = displayRect(bounds, pageSize: pageSize)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(
                    overlappingFields.isEmpty
                        ? PPColor.accent.opacity(0.08)
                        : PPColor.amber.opacity(0.12)
                )
            Rectangle()
                .stroke(
                    overlappingFields.isEmpty
                        ? PPColor.accent
                        : PPColor.amber,
                    lineWidth: 2
                )
            HStack(spacing: 4) {
                Image(systemName: kind.symbol)
                Text(
                    fieldName.isEmpty
                        ? kind.title.localizedUI
                        : fieldName
                )
                    .lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(
                overlappingFields.isEmpty
                    ? PPColor.accent
                    : PPColor.amber
            )
            .padding(4)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let origin = dragStartBounds ?? bounds
                    if dragStartBounds == nil {
                        dragStartBounds = origin
                    }
                    let x = origin.x
                        + value.translation.width
                        / max(1, pageSize.width)
                    let y = origin.y
                        + value.translation.height
                        / max(1, pageSize.height)
                    bounds = PDFNormalizedRect(
                        x: min(
                            max(x, 0),
                            1 - bounds.width
                        ),
                        y: min(
                            max(y, 0),
                            1 - bounds.height
                        ),
                        width: bounds.width,
                        height: bounds.height
                    )
                }
                .onEnded { _ in
                    dragStartBounds = nil
                }
        )
        .accessibilityLabel("\(kind.title) field placement")
        .accessibilityValue(
            "\(Int(bounds.x * 100)) percent from left, \(Int(bounds.y * 100)) percent from top"
        )
    }

    private var controls: some View {
        VStack(spacing: PPSpacing.medium) {
            HStack {
                Label("Field type", systemImage: kind.symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Field type", selection: $kind) {
                    ForEach(
                        PDFFormFieldKind.allCases.filter(\.canCreate)
                    ) { option in
                        Label(
                            option.title.localizedUI,
                            systemImage: option.symbol
                        )
                            .tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("formFieldTypePicker")
            }

            HStack(spacing: PPSpacing.medium) {
                TextField("Field name", text: $fieldName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("formFieldName")
                Toggle("Required", isOn: $isRequired)
                    .font(.subheadline)
                    .fixedSize()
            }

            HStack(spacing: PPSpacing.medium) {
                pageStepper
                Spacer()
                if kind == .text {
                    Toggle("Multiline", isOn: $isMultiline)
                        .font(.subheadline)
                }
            }

            if kind == .radio || kind == .choice {
                TextField(
                    "Options, one per line",
                    text: $optionsText,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("formFieldOptions")
            }

            if kind == .choice {
                Toggle("Show options as a list", isOn: $isListChoice)
                    .font(.subheadline)
                    .accessibilityIdentifier("formChoiceListMode")
            }

            if kind == .text {
                Stepper(
                    maximumLength == 0
                        ? "No character limit"
                        : "Character limit: \(maximumLength)",
                    value: $maximumLength,
                    in: 0...4_000,
                    step: 50
                )
                .font(.subheadline)
            }

            PrecisionPlacementRail(
                bounds: $bounds,
                tint: overlappingFields.isEmpty
                    ? PPColor.accent
                    : PPColor.amber,
                title: "Field"
            )

            HStack(spacing: PPSpacing.medium) {
                Label("Width", systemImage: "arrow.left.and.right")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { bounds.width },
                        set: { setWidth($0) }
                    ),
                    in: kind == .checkbox
                        ? 0.08...0.14
                        : 0.18...0.82
                )
                Label("Height", systemImage: "arrow.up.and.down")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { bounds.height },
                        set: { setHeight($0) }
                    ),
                    in: kind == .checkbox
                        ? 0.04...0.14
                        : 0.04...0.42
                )
            }
            .foregroundStyle(PPColor.textSecondary)

            if let firstOverlap = overlappingFields.first {
                Label(
                    "Overlaps \(firstOverlap.name) on this page",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .lineLimit(1)
            }
        }
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var pageStepper: some View {
        HStack(spacing: PPSpacing.small) {
            Button {
                pageIndex = max(0, pageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(pageIndex == 0)
            Text("Page \(pageIndex + 1)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Button {
                pageIndex = min(maxPageIndex, pageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(pageIndex >= maxPageIndex)
        }
    }

    private var maxPageIndex: Int {
        max(0, (model.record(id: recordID)?.profile.pageCount ?? 1) - 1)
    }

    private var canAdd: Bool {
        !fieldName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            && fieldName.count <= 80
            && (
                kind != .radio && kind != .choice
                    || validOptions
            )
            && overlappingFields.isEmpty
    }

    private var options: [String] {
        optionsText.components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .filter { !$0.isEmpty }
    }

    private var validOptions: Bool {
        (2...12).contains(options.count)
            && options.allSatisfy { $0.count <= 64 }
            && Set(options.map { $0.lowercased() }).count
                == options.count
    }

    private var overlappingFields: [PDFFormFieldSnapshot] {
        let candidate = CGRect(
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height
        ).insetBy(dx: -0.006, dy: -0.006)
        return existingFields.filter {
            guard $0.pageIndex == pageIndex else { return false }
            let existing = CGRect(
                x: $0.normalizedBounds.x,
                y: $0.normalizedBounds.y,
                width: $0.normalizedBounds.width,
                height: $0.normalizedBounds.height
            )
            return candidate.intersects(existing)
        }
    }

    private func addField() {
        isSaving = true
        let payload = PDFFormFieldPayload(
            pageIndex: pageIndex,
            kind: kind,
            name: fieldName,
            normalizedBounds: bounds,
            isRequired: isRequired,
            isMultiline: isMultiline,
            maximumLength: maximumLength > 0
                ? maximumLength
                : nil,
            options: options,
            isListChoice: isListChoice
        )
        saveTask = Task {
            let succeeded = await model.addFormField(
                recordID: recordID,
                payload: payload
            )
            guard !Task.isCancelled else {
                isSaving = false
                saveTask = nil
                return
            }
            isSaving = false
            saveTask = nil
            guard succeeded else { return }
            dismiss()
            onCreated()
        }
    }

    private func resizeForKind(
        _ kind: PDFFormFieldKind
    ) {
        let size: (Double, Double)
        switch kind {
        case .checkbox:
            size = (0.075, 0.058)
        case .radio:
            size = (
                0.42,
                min(
                    0.42,
                    max(0.12, Double(max(2, options.count)) * 0.052)
                )
            )
        case .choice:
            size = (0.42, isListChoice ? 0.18 : 0.07)
        case .signature:
            size = (0.38, 0.09)
        default:
            size = (0.42, isMultiline ? 0.14 : 0.07)
        }
        bounds = PDFNormalizedRect(
            x: min(bounds.x, 1 - size.0),
            y: min(bounds.y, 1 - size.1),
            width: size.0,
            height: size.1
        )
    }

    private func setWidth(_ width: Double) {
        bounds = PDFNormalizedRect(
            x: min(bounds.x, 1 - width),
            y: bounds.y,
            width: width,
            height: bounds.height
        )
    }

    private func setHeight(_ height: Double) {
        bounds = PDFNormalizedRect(
            x: bounds.x,
            y: min(bounds.y, 1 - height),
            width: bounds.width,
            height: height
        )
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

    private func displayRect(
        _ bounds: PDFNormalizedRect,
        pageSize: CGSize
    ) -> CGRect {
        CGRect(
            x: bounds.x * pageSize.width,
            y: bounds.y * pageSize.height,
            width: bounds.width * pageSize.width,
            height: bounds.height * pageSize.height
        )
    }

    private func loadPage() async {
        guard let url = model.url(for: recordID) else { return }
        let selectedPage = pageIndex
        let preview = await PDFEditorPreviewLoader.shared.preview(
            url: url,
            pageIndex: selectedPage,
            revision: model.refreshToken(for: recordID)
        )
        guard !Task.isCancelled,
              pageIndex == selectedPage,
              let preview
        else { return }
        pagePreview = preview.image
        pageAspectRatio = CGFloat(preview.aspectRatio)
    }

    private static func suggestedPlacement(
        pageIndex: Int,
        existingFields: [PDFFormFieldSnapshot],
        width: Double,
        height: Double
    ) -> PDFNormalizedRect {
        let x = min(0.29, 1 - width)
        let existing = existingFields
            .filter { $0.pageIndex == pageIndex }
            .map {
                CGRect(
                    x: $0.normalizedBounds.x - 0.015,
                    y: $0.normalizedBounds.y - 0.015,
                    width: $0.normalizedBounds.width + 0.03,
                    height: $0.normalizedBounds.height + 0.03
                )
            }
        let candidates = [0.8, 0.55, 0.36, 0.18]
        for y in candidates where y + height <= 0.96 {
            let candidate = CGRect(
                x: x,
                y: y,
                width: width,
                height: height
            )
            if !existing.contains(where: candidate.intersects) {
                return PDFNormalizedRect(
                    x: x,
                    y: y,
                    width: width,
                    height: height
                )
            }
        }
        return PDFNormalizedRect(
            x: x,
            y: max(0.02, 0.96 - height),
            width: width,
            height: height
        )
    }
}
