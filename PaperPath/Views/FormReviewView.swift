import PDFKit
import SwiftUI

struct FormReviewView: View {
    private enum FieldFilter: String, CaseIterable, Identifiable, Sendable {
        case all
        case required
        case incomplete
        case complete

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .required: return "Required"
            case .incomplete: return "Incomplete"
            case .complete: return "Done"
            }
        }
    }

    private struct InspectionRequest: Hashable {
        let recordID: UUID
        let revisionID: UUID?
        let isAvailable: Bool
    }

    private struct FieldProjectionRequest: Hashable {
        let generation: UUID
        let filter: FieldFilter
        let query: String
        let pageIndex: Int?
        let isAvailable: Bool
    }

    private struct FieldCreationContext: Identifiable {
        let id = UUID()
        let revisionID: UUID
        let fields: [PDFFormFieldSnapshot]
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let initialPageIndex: Int
    let onSelectPage: (Int, Bool) -> Void
    let onSignField: (PDFFormFieldSnapshot, Bool) -> Void
    let onPrepare: () -> Void

    @State private var report = PDFFormInspectionReport.empty
    @State private var reportContentRevisionID: UUID?
    @State private var isLoading = true
    @State private var reportErrorMessage: String?
    @State private var fieldCreationContext: FieldCreationContext?
    @State private var reloadAfterAddingField = false
    @State private var isSharingForCompatibility = false
    @State private var compatibilityShareURL: URL?
    @State private var compatibilityShareTask: Task<Void, Never>?
    @State private var compatibilityShareGeneration = UUID()
    @State private var compatibilityShareProgress:
        PDFOperationProgress?
    @State private var compatibilityShareRateWindow = ByteRateWindow()
    @State private var compatibilityShareErrorMessage: String?
    @State private var compatibilityShareErrorFeedback = 0
    @State private var isRefreshingAutomation = false
    @State private var automationErrorMessage: String?
    @State private var automationErrorFeedback = 0
    @State private var fieldFilter = FieldFilter.all
    @State private var searchText = ""
    @State private var limitsFieldsToPage = false
    @State private var fieldPageIndex = 0
    @State private var isSearchPresented = false
    @State private var sortedFields: [PDFFormFieldSnapshot] = []
    @State private var fieldListGeneration = UUID()
    @State private var displayedFieldRequest: FieldProjectionRequest?
    @State private var isFilteringFields = false
    @State private var displayedFields: [PDFFormFieldSnapshot] = []
    @State private var didChooseInitialFieldFilter = false
    @State private var openingFieldID: String?
    @State private var reportGeneration = UUID()
    @State private var reportReloadTask: Task<Void, Never>?
    @State private var reportReloadGeneration = UUID()
    @State private var automationTask: Task<Void, Never>?
    @State private var automationGeneration = UUID()
    @State private var automationStopRequested = false
    @State private var checkpointTask: Task<Void, Never>?
    @State private var checkpointGeneration = UUID()
    @State private var checkpointWarningFeedback = 0
    @State private var protectedDataAvailable =
        UIApplication.shared.isProtectedDataAvailable

    init(
        recordID: UUID,
        initialPageIndex: Int = 0,
        onSelectPage: @escaping (Int, Bool) -> Void,
        onSignField: @escaping (
            PDFFormFieldSnapshot,
            Bool
        ) -> Void = { _, _ in },
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

    private var isFormActionUnavailable: Bool {
        !canReadForm || isLoading || isRefreshingAutomation
            || compatibilityShareTask != nil
            || checkpointTask != nil
            || model.isProcessing(recordID)
            || reportContentRevisionID
                != model.record(id: recordID)?.contentRevisionID
    }

    private var canReadForm: Bool {
        scenePhase == .active && protectedDataAvailable
            && UIApplication.shared.isProtectedDataAvailable
    }

    private var inspectionRequest: InspectionRequest {
        InspectionRequest(
            recordID: recordID,
            revisionID: model.record(id: recordID)?.contentRevisionID,
            isAvailable: canReadForm
        )
    }

    private var fieldProjectionRequest: FieldProjectionRequest {
        FieldProjectionRequest(
            generation: fieldListGeneration,
            filter: fieldFilter,
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            pageIndex: limitsFieldsToPage ? fieldPageIndex : nil,
            isAvailable: canReadForm && !isLoading && reportErrorMessage == nil
        )
    }

    private var completionRatio: Double {
        guard !fields.isEmpty else { return 0 }
        let incompleteCount =
            report.incompleteRequiredFields.count
            + report.incompleteOptionalFields.count
        return Double(max(0, fields.count - incompleteCount))
            / Double(fields.count)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    PPEmptyState(
                        kind: .processing,
                        title: "Checking form fields",
                        message: "Reading the private working copy on this device."
                    )
                    .padding(PPSpacing.regular)
                } else if let reportErrorMessage {
                    VStack(spacing: PPSpacing.medium) {
                        PPEmptyState(
                            kind: .tools,
                            title: "Couldn’t inspect form",
                            message: reportErrorMessage
                        )
                        Button {
                            reloadReport()
                        } label: {
                            Label(
                                "Inspect Again",
                                systemImage: "arrow.clockwise"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PPPrimaryButtonStyle())
                        .accessibilityIdentifier(
                            "retryFormInspection"
                        )
                    }
                    .frame(maxWidth: 520)
                    .padding(PPSpacing.regular)
                } else {
                    formContent
                }
            }
            .background(PPColor.canvas)
            .navigationTitle("Fill Form")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            automationStopRequested
                                ? "Stopping"
                                : isRefreshingAutomation
                                    || compatibilityShareTask != nil
                                    || checkpointTask != nil
                                    ? "Stop"
                                    : "Close"
                        ).localizedUI
                    ) {
                        if isRefreshingAutomation {
                            stopAutomationRefresh()
                        } else if compatibilityShareTask != nil {
                            stopCompatibilityShare()
                        } else if checkpointTask != nil {
                            stopFieldOpening()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(automationStopRequested)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSearchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(isFormActionUnavailable || fields.isEmpty)
                    .accessibilityLabel("Search fields and values".localizedUI)
                    .help("Search fields and values".localizedUI)
                }
            }
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                prompt: Text("Search fields and values".localizedUI)
            )
            .task(id: inspectionRequest) {
                guard canReadForm else { return }
                if reportContentRevisionID != inspectionRequest.revisionID {
                    stopFieldOpening()
                    stopCompatibilityShare()
                    isSharingForCompatibility = false
                    cleanupCompatibilityShare()
                }
                await model.withFeedbackTarget(paperPathSceneID) {
                    await loadReport()
                }
            }
            .task(id: fieldProjectionRequest) {
                await projectFields()
            }
            .onChange(of: searchText) { _, text in
                let bounded = String(text.prefix(256))
                if bounded != text { searchText = bounded }
            }
            .fullScreenCover(
                item: $fieldCreationContext,
                onDismiss: completeFieldCreation
            ) { context in
                PDFFormFieldEditorView(
                    recordID: recordID,
                    contentRevisionID: context.revisionID,
                    initialPageIndex: initialPageIndex,
                    existingFields: context.fields,
                    onCommitted: {
                        reloadAfterAddingField = true
                    }
                ) {
                    reloadAfterAddingField = true
                    fieldCreationContext = nil
                }
            }
            .sheet(
                isPresented: $isSharingForCompatibility,
                onDismiss: cleanupCompatibilityShare
            ) {
                if let url = compatibilityShareURL {
                    ShareSheet(items: [url])
                }
            }
            .interactiveDismissDisabled(
                isRefreshingAutomation
                    || compatibilityShareTask != nil
                    || checkpointTask != nil
            )
            .accessibilityAction(.escape) {
                if isRefreshingAutomation {
                    stopAutomationRefresh()
                } else if compatibilityShareTask != nil {
                    stopCompatibilityShare()
                } else if checkpointTask != nil {
                    stopFieldOpening()
                } else {
                    dismiss()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    interruptProtectedFormWork()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                protectedDataAvailable = false
                interruptProtectedFormWork()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.protectedDataDidBecomeAvailableNotification
                )
            ) { _ in
                protectedDataAvailable = true
            }
            .onDisappear {
                if fieldCreationContext == nil {
                    interruptProtectedFormWork()
                }
            }
            .sensoryFeedback(
                .error,
                trigger: reportErrorMessage
            )
            .sensoryFeedback(
                .error,
                trigger: compatibilityShareErrorFeedback
            )
            .sensoryFeedback(
                .error,
                trigger: automationErrorFeedback
            )
            .sensoryFeedback(
                .warning,
                trigger: checkpointWarningFeedback
            )
            .sensoryFeedback(
                .selection,
                trigger: fieldFilter
            )
        }
    }

    private var formContent: some View {
        List {
            Section {
                compatibilitySummary
            }
            .listRowBackground(PPColor.surface)

            if report.requiresCompatibleReader {
                Section("Continue safely") {
                    Button {
                        prepareCompatibilityShare()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    compatibilityShareActionTitle
                                )
                                    .foregroundStyle(PPColor.textPrimary)
                                Text(
                                    "The private working copy keeps the original form data intact."
                                )
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                            }
                        } icon: {
                            if compatibilityShareTask != nil {
                                ProgressView()
                            } else if compatibilityShareErrorMessage != nil {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(PPColor.amber)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(PPColor.accent)
                            }
                        }
                    }
                    .disabled(isFormActionUnavailable)
                    .accessibilityLabel(
                        compatibilityShareActionTitle
                    )
                    .accessibilityHint(
                        compatibilityShareAccessibilityHint
                    )
                    .accessibilityIdentifier(
                        "shareFormWithCompatibleReader"
                    )
                    if let compatibilityShareProgress {
                        LocalOperationProgressView(
                            progress: compatibilityShareProgress
                        )
                    }
                    if let compatibilityShareErrorMessage {
                        Label(
                            compatibilityShareErrorMessage.localizedUI,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "formCompatibilityShareError"
                        )
                    }
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
                    fieldFilterControl
                    Toggle("Fields on one page".localizedUI, isOn: $limitsFieldsToPage)
                    if limitsFieldsToPage {
                        Stepper(
                            AppLocalization.format("Page %lld", fieldPageIndex + 1),
                            value: $fieldPageIndex,
                            in: 0...max(0, (model.record(id: recordID)?.profile.pageCount ?? 1) - 1)
                        )
                    }
                }

                Section(fieldSectionTitle.localizedUI) {
                    if isFilteringFields || displayedFieldRequest != fieldProjectionRequest {
                        ProgressView("Filtering fields".localizedUI)
                            .frame(minHeight: 44)
                    } else if displayedFields.isEmpty {
                        Label(
                            "No fields match this filter".localizedUI,
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                        .foregroundStyle(PPColor.textSecondary)

                        Button("Show All Fields".localizedUI) {
                            fieldFilter = .all
                            searchText = ""
                            limitsFieldsToPage = false
                        }
                    } else {
                        ForEach(displayedFields) { field in
                            fieldRow(field)
                        }
                    }
                }

                if !report.hasXFA {
                    Section {
                        Button {
                            beginFieldCreation()
                        } label: {
                            Label("Add Field", systemImage: "plus")
                        }
                        .disabled(isFormActionUnavailable)
                        .accessibilityIdentifier(
                            "addFormFieldFromReview"
                        )
                    }
                }
            }

            if !report.issues.isEmpty {
                Section {
                    DisclosureGroup {
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
                    } label: {
                        Label(
                            "File compatibility",
                            systemImage: "doc.badge.gearshape"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if !report.automationFields.isEmpty
                || report.unsupportedJavaScriptCount > 0 {
                Section {
                    DisclosureGroup {
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
                                    automationRefreshActionTitle,
                                    systemImage:
                                        automationErrorMessage == nil
                                            ? "function"
                                            : "arrow.clockwise"
                                )
                            }
                            .disabled(
                                isFormActionUnavailable
                                    || !report.invalidAutomationFields.isEmpty
                            )
                            .accessibilityIdentifier(
                                "refreshFormCalculations"
                            )
                        }

                        if let automationErrorMessage {
                            Label(
                                automationErrorMessage.localizedUI,
                                systemImage:
                                    "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.amber)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                            .accessibilityIdentifier(
                                "formCalculationRefreshError"
                            )
                        }
                    } label: {
                        Label(
                            "Calculated fields",
                            systemImage: "function"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .frame(
            maxWidth: horizontalSizeClass == .regular
                ? 880
                : .infinity
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var fieldFilterControl: some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            Menu {
                ForEach(FieldFilter.allCases) { filter in
                    Button {
                        fieldFilter = filter
                    } label: {
                        Label(
                            filter.title.localizedUI,
                            systemImage: fieldFilter == filter
                                ? "checkmark"
                                : "line.3.horizontal.decrease"
                        )
                    }
                }
            } label: {
                HStack(spacing: PPSpacing.small) {
                    Label(
                        "Field filter",
                        systemImage: "line.3.horizontal.decrease"
                    )
                    .font(.subheadline.weight(.semibold))
                    Spacer(minLength: PPSpacing.small)
                    Text(fieldFilter.title.localizedUI)
                        .foregroundStyle(PPColor.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(fieldFilter.title.localizedUI)
        } else {
            Picker("Field filter", selection: $fieldFilter) {
                ForEach(FieldFilter.allCases) { filter in
                    Text(filter.title.localizedUI)
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var compatibilitySummary: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            WorkflowCommandHeader(
                eyebrow: "FORM",
                title: formStatusTitle,
                detail: summaryDetail,
                symbol: report.isReadyForVerifiedOutput
                    ? "checkmark.circle"
                    : "list.bullet.clipboard",
                tint: compatibilityColor,
                metrics: []
            )

            if !fields.isEmpty {
                ProgressView(value: completionRatio)
                    .tint(
                        report.incompleteRequiredFields.isEmpty
                            ? PPColor.mint
                            : PPColor.accent
                    )
                    .accessibilityLabel("Form completion".localizedUI)
                    .accessibilityValue(
                        AppLocalization.format(
                            "%lld percent",
                            Int(completionRatio * 100)
                        )
                    )
            }

            if fields.isEmpty, !report.hasXFA {
                Button {
                    beginFieldCreation()
                } label: {
                    Label("Add Field", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(isFormActionUnavailable)
                .accessibilityIdentifier("addFirstFormField")
            } else if let next = nextIncompleteField,
                      !report.isReadyForVerifiedOutput {
                Button {
                    open(next)
                } label: {
                    Group {
                        if openingFieldID == next.id {
                            HStack(spacing: PPSpacing.small) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(
                                    AppLocalization.format(
                                        "Opening %@",
                                        next.name
                                    )
                                )
                            }
                        } else {
                            Label(
                                next.kind == .signature
                                    ? AppLocalization.format(
                                        "Sign %@",
                                        next.name
                                    )
                                    : AppLocalization.format(
                                        "Continue with %@",
                                        next.name
                                    ),
                                systemImage: next.kind == .signature
                                    ? "signature"
                                    : "arrow.right"
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(isFormActionUnavailable)
                .accessibilityIdentifier("continueRequiredFormField")
                .accessibilityHint(
                    fieldAccessibilityHint(next)
                )
            }
            if report.isReadyForVerifiedOutput {
                Button {
                    onPrepare()
                } label: {
                    Label(
                        "Finish & Share",
                        systemImage: "checkmark.shield"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(isFormActionUnavailable)
                .accessibilityIdentifier("formVerifyAndShare")
                .accessibilityHint(
                    "Checks the final copy before sharing"
                )
            }
        }
        .padding(.vertical, PPSpacing.xSmall)
    }

    private var compatibilityShareActionTitle: String {
        (
            compatibilityShareTask != nil
                ? "Verifying protected copy"
                : compatibilityShareErrorMessage != nil
                    ? "Retry checked copy"
                    : "Open a copy in another app"
        ).localizedUI
    }

    private var compatibilityShareAccessibilityHint: String {
        (
            compatibilityShareErrorMessage == nil
                ? "Checks file identity, size, page count, and SHA-256 before sharing."
                : "Retries verification without changing the private working copy."
        ).localizedUI
    }

    private var automationRefreshActionTitle: String {
        (
            automationErrorMessage != nil
                ? "Retry Calculations"
                : report.fieldsNeedingAutomationUpdate.isEmpty
                    ? "Recheck Calculations"
                    : "Refresh Calculations"
        ).localizedUI
    }

    private func fieldRow(
        _ field: PDFFormFieldSnapshot
    ) -> some View {
        Button {
            open(field)
        } label: {
            HStack(alignment: .top, spacing: PPSpacing.medium) {
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
                    fieldHeading(field)
                    Text(fieldDetail(field).localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout ? 3 : 2
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PPSpacing.xSmall)
                if openingFieldID == field.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(
                        systemName:
                            "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                }
            }
        }
        .disabled(
            isFormActionUnavailable || isFilteringFields
                || displayedFieldRequest != fieldProjectionRequest
        )
        .help("Open on Page".localizedUI)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(field.name)
        .accessibilityValue(fieldAccessibilityValue(field))
        .accessibilityHint(fieldAccessibilityHint(field))
        .accessibilityIdentifier(
            "formField-\(field.pageIndex)-\(field.annotationIndex)"
        )
    }

    @ViewBuilder
    private func fieldHeading(
        _ field: PDFFormFieldSnapshot
    ) -> some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            VStack(alignment: .leading, spacing: 3) {
                fieldName(field)
                fieldBadges(field)
            }
        } else {
            HStack(spacing: 6) {
                fieldName(field)
                fieldBadges(field)
            }
        }
    }

    private func fieldName(
        _ field: PDFFormFieldSnapshot
    ) -> some View {
        Text(field.name)
            .foregroundStyle(PPColor.textPrimary)
            .lineLimit(dynamicTypeSize.ppPrefersExpandedLayout ? 3 : 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func fieldBadges(
        _ field: PDFFormFieldSnapshot
    ) -> some View {
        HStack(spacing: 6) {
            if field.isRequired {
                Text("REQUIRED")
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.amber)
            }
            if field.isReadOnly {
                Label("Read only", systemImage: "lock")
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
    }

    private func fieldAccessibilityValue(
        _ field: PDFFormFieldSnapshot
    ) -> String {
        var parts = [fieldDetail(field).localizedUI]
        if field.isRequired {
            parts.append("Required".localizedUI)
        }
        if field.isReadOnly {
            parts.append("Read only".localizedUI)
        }
        if openingFieldID == field.id {
            parts.append("Opening".localizedUI)
        }
        return parts.joined(separator: ", ")
    }

    private func fieldAccessibilityHint(
        _ field: PDFFormFieldSnapshot
    ) -> String {
        if openingFieldID == field.id {
            return "Saving the resume point before opening this field."
                .localizedUI
        }
        if openingFieldID != nil {
            return "Wait for the selected field to open.".localizedUI
        }
        return isActionableSignature(field)
            ? AppLocalization.format(
                "Opens signature placement on page %lld",
                field.pageIndex + 1
            )
            : AppLocalization.format(
                "Opens page %lld",
                field.pageIndex + 1
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
            return AppLocalization.format(
                "%lld value%@ need%@ format or range correction",
                count,
                count == 1 ? "" : "s",
                count == 1 ? "s" : ""
            )
        }
        if !report.fieldsNeedingAutomationUpdate.isEmpty {
            let count = report.fieldsNeedingAutomationUpdate.count
            return AppLocalization.format(
                "%lld calculated field%@ ready to refresh locally",
                count,
                count == 1 ? "" : "s"
            )
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

    private var formStatusTitle: String {
        if fields.isEmpty {
            return "No fillable fields"
        }
        let remaining = report.incompleteRequiredFields.count
        if remaining > 0 {
            return AppLocalization.format(
                "%lld required field%@ left",
                remaining,
                remaining == 1 ? "" : "s"
            )
        }
        return "Ready to finish"
    }

    private var fieldSectionTitle: String {
        switch fieldFilter {
        case .all:
            return report.incompleteRequiredFields.isEmpty
                ? "Fields"
                : "Required first"
        case .required:
            return "Required fields"
        case .incomplete:
            return "Incomplete fields"
        case .complete:
            return "Completed fields"
        }
    }

    private var nextIncompleteField: PDFFormFieldSnapshot? {
        sortedFields.first {
            !$0.isComplete && !$0.isReadOnly && $0.issue == nil
                && (!limitsFieldsToPage || $0.pageIndex == fieldPageIndex)
        }
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
                    Text(
                        AppLocalization.format(
                            "Preview: %@",
                            preview
                        )
                    )
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
        guard canReadForm, !Task.isCancelled else { return }
        let generation = UUID()
        reportGeneration = generation
        isLoading = true
        reportErrorMessage = nil
        defer {
            if reportGeneration == generation {
                isLoading = false
            }
        }
        guard let contentRevisionID =
            model.record(id: recordID)?.contentRevisionID
        else {
            reportErrorMessage =
                "The private working copy could not be inspected. Try again."
            return
        }
        do {
            let loadedReport = try await model.inspectForm(
                recordID: recordID
            )
            let sortTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let ordered = loadedReport.fields.map {
                    (field: $0, complete: $0.isComplete)
                }.sorted {
                    if ($0.field.issue != nil) != ($1.field.issue != nil) {
                        return $0.field.issue != nil
                    }
                    if $0.field.isRequired != $1.field.isRequired { return $0.field.isRequired }
                    if $0.complete != $1.complete { return !$0.complete }
                    if $0.field.pageIndex != $1.field.pageIndex {
                        return $0.field.pageIndex < $1.field.pageIndex
                    }
                    if $0.field.name != $1.field.name { return $0.field.name < $1.field.name }
                    return $0.field.annotationIndex < $1.field.annotationIndex
                }.map(\.field)
                try Task.checkCancellation()
                return ordered
            }
            let orderedFields = try await withTaskCancellationHandler {
                try await sortTask.value
            } onCancel: {
                sortTask.cancel()
            }
            guard !Task.isCancelled,
                  canReadForm,
                  reportGeneration == generation,
                  model.record(id: recordID)?.contentRevisionID
                    == contentRevisionID
            else { return }
            report = loadedReport
            sortedFields = orderedFields
            fieldListGeneration = UUID()
            reportContentRevisionID = contentRevisionID
            automationErrorMessage = nil
            let hasIncompleteFields =
                !loadedReport.incompleteRequiredFields.isEmpty
                || !loadedReport.incompleteOptionalFields.isEmpty
            if !didChooseInitialFieldFilter {
                fieldFilter = hasIncompleteFields ? .incomplete : .all
                fieldPageIndex = min(
                    max(0, initialPageIndex),
                    max(0, (model.record(id: recordID)?.profile.pageCount ?? 1) - 1)
                )
                didChooseInitialFieldFilter = true
            } else if fieldFilter == .incomplete,
                      !hasIncompleteFields {
                fieldFilter = .all
            }
            fieldPageIndex = min(
                fieldPageIndex,
                max(0, (model.record(id: recordID)?.profile.pageCount ?? 1) - 1)
            )
            let checkpoint: DocumentTaskCheckpoint?
            if let next = loadedReport.incompleteRequiredFields.first {
                checkpoint = DocumentTaskCheckpoint(
                    stage: next.kind == .signature ? .sign : .fillForm,
                    pageIndex: next.pageIndex,
                    fieldName: next.name,
                    normalizedBounds: next.kind == .signature
                        ? next.normalizedBounds
                        : nil,
                    contentRevisionID: contentRevisionID
                )
            } else if loadedReport.isReadyForVerifiedOutput {
                checkpoint = DocumentTaskCheckpoint(
                    stage: .verify,
                    contentRevisionID: contentRevisionID
                )
            } else if loadedReport.hasXFA {
                checkpoint = DocumentTaskCheckpoint(
                    stage: .fillForm,
                    contentRevisionID: contentRevisionID
                )
            } else {
                checkpoint = nil
            }
            await model.updateTaskCheckpoint(
                recordID: recordID,
                checkpoint: checkpoint,
                expectedContentRevisionID: contentRevisionID
            )
            guard !Task.isCancelled,
                  reportGeneration == generation,
                  model.record(id: recordID)?.contentRevisionID
                    == contentRevisionID
            else { return }
            if !loadedReport.fields.isEmpty {
                await model.setActionCompletion(
                    recordID: recordID,
                    action: .reviewForm,
                    completed:
                        loadedReport.incompleteRequiredFields.isEmpty
                            && loadedReport.compatibility
                                != .unsupported,
                    expectedContentRevisionID: contentRevisionID
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard reportGeneration == generation, canReadForm,
                  !Task.isCancelled,
                  model.record(id: recordID)?.contentRevisionID == contentRevisionID
            else { return }
            reportErrorMessage =
                "The private working copy could not be inspected. Try again."
            model.present(error, in: paperPathSceneID)
        }
    }

    private func reloadReport() {
        reportReloadTask?.cancel()
        let generation = UUID()
        reportReloadGeneration = generation
        reportReloadTask = Task { @MainActor in
            defer {
                if reportReloadGeneration == generation {
                    reportReloadTask = nil
                }
            }
            await model.withFeedbackTarget(paperPathSceneID) {
                await loadReport()
            }
        }
    }

    private func refreshAutomation() {
        guard !isFormActionUnavailable, let revisionID = reportContentRevisionID
        else { return }
        automationErrorMessage = nil
        let generation = UUID()
        automationGeneration = generation
        automationStopRequested = false
        isRefreshingAutomation = true
        automationTask = Task { @MainActor in
            let succeeded = await model.withFeedbackTarget(paperPathSceneID) {
                await model.refreshFormAutomation(
                    recordID: recordID,
                    expectedContentRevisionID: revisionID,
                    presentsFeedback: false
                )
            }
            guard automationGeneration == generation else { return }
            let wasStopped =
                automationStopRequested || Task.isCancelled
            isRefreshingAutomation = false
            automationTask = nil
            automationStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    succeeded
                        ? "Form update finished before stopping · changes kept"
                        : "Form update stopped · working copy unchanged"
                ).localizedUI
                if succeeded {
                    reloadReport()
                }
                return
            }
            guard succeeded else {
                automationErrorMessage =
                    "Calculated fields could not be refreshed. Try again."
                automationErrorFeedback += 1
                return
            }
            await model.withFeedbackTarget(paperPathSceneID) {
                await loadReport()
            }
        }
    }

    private func prepareCompatibilityShare() {
        guard !isFormActionUnavailable, let revisionID = reportContentRevisionID
        else { return }
        cleanupCompatibilityShare()
        compatibilityShareErrorMessage = nil
        let generation = UUID()
        compatibilityShareGeneration = generation
        compatibilityShareRateWindow.reset()
        compatibilityShareProgress = PDFOperationProgress(
            label: "Verifying protected copy",
            fractionCompleted: 0,
            byteStage: .checksumming
        )
        compatibilityShareTask = Task { @MainActor in
            let url = await model.withFeedbackTarget(paperPathSceneID) {
                await model.makeFilesExportCopy(
                    recordID: recordID,
                    presentsFeedback: false
                ) { update in
                    guard compatibilityShareGeneration == generation
                    else { return }
                    if let progress = compatibilityShareRateWindow
                        .operationProgress(
                            label: "Verifying protected copy",
                            update: update,
                            current: compatibilityShareProgress
                        ) {
                        compatibilityShareProgress = progress
                    }
                }
            }
            guard compatibilityShareGeneration == generation else {
                if let url {
                    await model.discardFilesExportCopy(at: url)
                }
                return
            }
            compatibilityShareTask = nil
            compatibilityShareProgress = nil
            compatibilityShareRateWindow.reset()
            guard !Task.isCancelled, canReadForm,
                  model.record(id: recordID)?.contentRevisionID == revisionID
            else {
                if let url {
                    await model.discardFilesExportCopy(at: url)
                }
                return
            }
            guard let url else {
                compatibilityShareErrorMessage =
                    "The checked sharing copy could not be prepared. Try again."
                compatibilityShareErrorFeedback += 1
                return
            }
            compatibilityShareURL = url
            isSharingForCompatibility = true
        }
    }

    private func stopCompatibilityShare() {
        compatibilityShareGeneration = UUID()
        compatibilityShareTask?.cancel()
        compatibilityShareTask = nil
        compatibilityShareProgress = nil
        compatibilityShareRateWindow.reset()
    }

    private func stopAutomationRefresh(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            automationGeneration = UUID()
            automationStopRequested = false
        } else {
            guard automationTask != nil,
                  !automationStopRequested
            else { return }
            automationStopRequested = true
        }
        automationTask?.cancel()
        if invalidateResult {
            automationTask = nil
            isRefreshingAutomation = false
        }
    }

    private func cleanupCompatibilityShare() {
        let url = compatibilityShareURL
        compatibilityShareURL = nil
        guard let url else { return }
        Task {
            await model.discardFilesExportCopy(at: url)
        }
    }

    private func interruptProtectedFormWork() {
        reportGeneration = UUID()
        reportReloadGeneration = UUID()
        reportReloadTask?.cancel()
        reportReloadTask = nil
        stopAutomationRefresh(invalidateResult: true)
        stopFieldOpening()
        stopCompatibilityShare()
        compatibilityShareErrorMessage = nil
        automationErrorMessage = nil
        isSharingForCompatibility = false
        cleanupCompatibilityShare()
        report = .empty
        reportContentRevisionID = nil
        sortedFields = []
        searchText = ""
        isSearchPresented = false
        fieldListGeneration = UUID()
        displayedFieldRequest = nil
        isFilteringFields = false
        displayedFields.removeAll(keepingCapacity: false)
        fieldCreationContext = nil
        reloadAfterAddingField = false
        isLoading = true
    }

    private func completeFieldCreation() {
        fieldCreationContext = nil
        guard reloadAfterAddingField else { return }
        reloadAfterAddingField = false
        reloadReport()
    }

    private func beginFieldCreation() {
        guard !isFormActionUnavailable, let revisionID = reportContentRevisionID else { return }
        fieldCreationContext = FieldCreationContext(revisionID: revisionID, fields: fields)
        isSearchPresented = false
    }

    private func stopFieldOpening() {
        checkpointGeneration = UUID()
        checkpointTask?.cancel()
        checkpointTask = nil
        openingFieldID = nil
    }

    private func open(_ field: PDFFormFieldSnapshot) {
        guard !isFormActionUnavailable,
              let reportContentRevisionID,
              let contentRevisionID =
                model.record(id: recordID)?.contentRevisionID,
              contentRevisionID == reportContentRevisionID
        else { return }
        let opensSignature = isActionableSignature(field)
        let checkpoint = DocumentTaskCheckpoint(
            stage: opensSignature ? .sign : .fillForm,
            pageIndex: field.pageIndex,
            fieldName: field.name,
            normalizedBounds: opensSignature
                ? field.normalizedBounds
                : nil,
            contentRevisionID: contentRevisionID
        )
        openingFieldID = field.id
        let generation = UUID()
        checkpointGeneration = generation
        checkpointTask = Task { @MainActor in
            defer {
                if checkpointGeneration == generation {
                    checkpointTask = nil
                    openingFieldID = nil
                }
            }
            let checkpointSaved = await model.withFeedbackTarget(paperPathSceneID) {
                await model.updateTaskCheckpoint(
                    recordID: recordID,
                    checkpoint: checkpoint,
                    presentsFeedback: false,
                    expectedContentRevisionID: contentRevisionID
                )
            }
            guard checkpointGeneration == generation,
                  !Task.isCancelled, canReadForm
            else { return }
            guard model.record(id: recordID)?.contentRevisionID
                    == contentRevisionID
            else {
                checkpointWarningFeedback += 1
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this field opened. Review the updated form."
                        .localizedUI
                reloadReport()
                return
            }
            if !checkpointSaved {
                checkpointWarningFeedback += 1
            }
            await Task.yield()
            guard checkpointGeneration == generation, !Task.isCancelled, canReadForm,
                  model.record(id: recordID)?.contentRevisionID == contentRevisionID
            else { return }
            if opensSignature {
                onSignField(field, checkpointSaved)
            } else {
                onSelectPage(field.pageIndex, checkpointSaved)
            }
        }
    }

    private func projectFields() async {
        let request = fieldProjectionRequest
        guard request.isAvailable else { return }
        isFilteringFields = true
        defer {
            if fieldProjectionRequest == request { isFilteringFields = false }
        }
        do {
            if !request.query.isEmpty {
                try await Task.sleep(for: .milliseconds(140))
            }
            let source = sortedFields
            let worker = Task.detached(priority: .userInitiated) {
                var matches: [PDFFormFieldSnapshot] = []
                for field in source {
                    try Task.checkCancellation()
                    let matchesFilter: Bool
                    switch request.filter {
                    case .all: matchesFilter = true
                    case .required: matchesFilter = field.isRequired
                    case .incomplete: matchesFilter = !field.isComplete
                    case .complete: matchesFilter = field.isComplete
                    }
                    guard matchesFilter,
                          request.pageIndex == nil || field.pageIndex == request.pageIndex,
                          request.query.isEmpty
                            || field.name.localizedStandardContains(request.query)
                            || field.value?.localizedStandardContains(request.query) == true
                    else { continue }
                    matches.append(field)
                }
                return matches
            }
            let matches = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, request == fieldProjectionRequest, canReadForm else { return }
            displayedFields = matches
            displayedFieldRequest = request
        } catch {
            return
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let contentRevisionID: UUID
    let existingFields: [PDFFormFieldSnapshot]
    let onCommitted: () -> Void
    let onCreated: () -> Void
    private let initialPageIndexValue: Int
    private let initialBounds: PDFNormalizedRect

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
    @State private var previewContentRevisionID: UUID?
    @State private var pageAspectRatio: CGFloat = 612 / 792
    @State private var isLoadingPagePreview = true
    @State private var previewErrorMessage: String?
    @State private var isSaving = false
    @State private var dragStartBounds: PDFNormalizedRect?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveGeneration = UUID()
    @State private var saveStopRequested = false
    @State private var didCommitField = false
    @State private var previewGeneration = 0
    @State private var previewReloadToken = UUID()
    @State private var isConfirmingDiscard = false
    @State private var saveErrorMessage: String?
    @State private var saveErrorFeedback = 0

    init(
        recordID: UUID,
        contentRevisionID: UUID,
        initialPageIndex: Int,
        existingFields: [PDFFormFieldSnapshot],
        onCommitted: @escaping () -> Void = {},
        onCreated: @escaping () -> Void
    ) {
        self.recordID = recordID
        self.contentRevisionID = contentRevisionID
        self.existingFields = existingFields
        self.onCommitted = onCommitted
        self.onCreated = onCreated
        let pageIndex = max(0, initialPageIndex)
        let initialBounds = Self.suggestedPlacement(
            pageIndex: pageIndex,
            existingFields: existingFields,
            width: 0.42,
            height: 0.07
        )
        self.initialPageIndexValue = pageIndex
        self.initialBounds = initialBounds
        _pageIndex = State(initialValue: pageIndex)
        _bounds = State(initialValue: initialBounds)
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
                    Button(
                        (
                            saveStopRequested
                                ? "Stopping"
                                : isSaving
                                    ? "Stop"
                                    : didCommitField
                                        ? "Done"
                                        : "Cancel"
                        ).localizedUI
                    ) {
                        if isSaving {
                            stopFieldSave()
                        } else {
                            requestDismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saveStopRequested)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addField() }
                        .disabled(
                            !canAdd
                                || isSaving
                                || didCommitField
                                || model.isProcessing(recordID)
                        )
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint(addFieldAccessibilityHint)
                        .accessibilityIdentifier("addFormField")
                }
            }
            .task(id: pagePreviewRequestID) {
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
            .onChange(of: isMultiline) { _, _ in
                guard kind == .text else { return }
                resizeForKind(kind)
            }
            .onChange(
                of: model.record(id: recordID)?.contentRevisionID
            ) { _, revision in
                guard !isSaving, !didCommitField,
                      revision != contentRevisionID
                else { return }
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                interruptProtectedFieldWork()
                dismiss()
            }
            .onChange(of: optionsText) { _, _ in
                guard kind == .radio else { return }
                resizeForKind(kind)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, pagePreview == nil {
                    previewReloadToken = UUID()
                } else if phase == .background {
                    interruptProtectedFieldEditing()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptProtectedFieldEditing()
            }
            .confirmationDialog(
                "Discard field draft?".localizedUI,
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
                    "The field has not been added to the PDF."
                        .localizedUI
                )
            }
            .interactiveDismissDisabled(isSaving || hasDraftChanges)
            .accessibilityAction(.escape) {
                if isSaving {
                    stopFieldSave()
                } else {
                    requestDismiss()
                }
            }
            .onDisappear {
                interruptProtectedFieldWork()
                fieldName = ""
                optionsText = ""
                saveErrorMessage = nil
            }
            .sensoryFeedback(.error, trigger: saveErrorFeedback)
        }
    }

    private var precisionContextBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PPSpacing.medium) {
                Label(
                    "Page \(pageIndex + 1)",
                    systemImage: "doc.text"
                )
                Label(
                    kind.title.localizedUI,
                    systemImage: kind.symbol
                )
                Label(
                    "\(Int(bounds.width * 100))×\(Int(bounds.height * 100))%",
                    systemImage:
                        "arrow.up.left.and.arrow.down.right"
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
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PPSpacing.regular)
        }
        .scrollIndicators(.hidden)
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        .frame(minHeight: 44)
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
                    existingFieldOverlays(pageSize: pageSize)
                    placementOverlay(pageSize: pageSize)
                } else if isLoadingPagePreview {
                    VStack(spacing: PPSpacing.small) {
                        ProgressView()
                        Text("Loading page preview".localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                } else {
                    VStack(spacing: PPSpacing.medium) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(PPColor.amber)
                        Text(
                            (
                                previewErrorMessage
                                    ?? "The page preview could not be loaded. Try again."
                            ).localizedUI
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        Button {
                            retryPagePreview()
                        } label: {
                            Label(
                                "Load Preview Again",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(
                            PPQuietButtonStyle(tint: PPColor.accent)
                        )
                        .accessibilityIdentifier(
                            "retryFormFieldPreview"
                        )
                    }
                    .padding(PPSpacing.regular)
                }
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
        .accessibilityLabel(
            AppLocalization.format(
                "%@ field placement",
                kind.title.localizedUI
            )
        )
        .accessibilityValue(
            AppLocalization.format(
                "%lld percent from left, %lld percent from top",
                Int(bounds.x * 100),
                Int(bounds.y * 100)
            )
        )
    }

    private var controls: some View {
        let overlaps = overlappingFields
        return ScrollView {
            VStack(spacing: PPSpacing.medium) {
                fieldTypeControl
                fieldIdentityControls
                pageAndTextControls

                if kind == .radio || kind == .choice {
                    HStack(alignment: .bottom) {
                        TextField(
                            "Options, one per line",
                            text: $optionsText,
                            axis: .vertical
                        )
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("formFieldOptions")
                        .onChange(of: optionsText) { _, value in
                            if value.count > 4_096 {
                                optionsText = String(
                                    value.prefix(4_096)
                                )
                            }
                            saveErrorMessage = nil
                        }
                        PasteButton(payloadType: String.self) {
                            values in
                            guard let value = values.first else {
                                return
                            }
                            optionsText = String(
                                value.prefix(4_096)
                            )
                        }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(isSaving)
                        .accessibilityLabel(
                            "Paste field options".localizedUI
                        )
                    }
                    if !optionsText.isEmpty, !validOptions {
                        Label(
                            "Use 2 to 12 unique options, up to 64 characters each.",
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.rose)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if kind == .choice {
                    Toggle(
                        "Show options as a list",
                        isOn: $isListChoice
                    )
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
                    tint: overlaps.isEmpty
                        ? PPColor.accent
                        : PPColor.amber,
                    title: "Field"
                )

                dimensionControls

                if let firstOverlap = overlaps.first {
                    Label(
                        "Overlaps \(firstOverlap.name) on this page",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let saveErrorMessage {
                    Label(
                        saveErrorMessage,
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.rose)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(PPSpacing.regular)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .disabled(isSaving || didCommitField)
        .frame(maxHeight: controlsMaximumHeight)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var fieldTypeControl: some View {
        HStack {
            Label("Field type", systemImage: kind.symbol)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: PPSpacing.small)
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
    }

    @ViewBuilder
    private var fieldIdentityControls: some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                fieldNameControl
                Toggle("Required", isOn: $isRequired)
                    .font(.subheadline)
            }
        } else {
            HStack(spacing: PPSpacing.medium) {
                fieldNameControl
                Toggle("Required", isOn: $isRequired)
                    .font(.subheadline)
                    .fixedSize()
            }
        }
    }

    private var fieldNameControl: some View {
        HStack(alignment: .center) {
            TextField("Field name", text: $fieldName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("formFieldName")
                .onChange(of: fieldName) { _, value in
                    if value.count > 80 {
                        fieldName = String(value.prefix(80))
                    }
                    saveErrorMessage = nil
                }
            PasteButton(payloadType: String.self) { values in
                guard let value = values.first else { return }
                let firstLine = value.components(
                    separatedBy: .newlines
                ).first ?? value
                fieldName = String(firstLine.prefix(80))
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(isSaving)
            .accessibilityLabel("Paste field name".localizedUI)
        }
    }

    @ViewBuilder
    private var pageAndTextControls: some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                pageStepper
                if kind == .text {
                    Toggle("Multiline", isOn: $isMultiline)
                        .font(.subheadline)
                }
            }
        } else {
            HStack {
                pageStepper
                Spacer(minLength: PPSpacing.small)
                if kind == .text {
                    Toggle("Multiline", isOn: $isMultiline)
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var dimensionControls: some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            VStack(spacing: PPSpacing.small) {
                dimensionControl(
                    title: "Width",
                    symbol: "arrow.left.and.right",
                    value: Binding(
                        get: { bounds.width },
                        set: { setWidth($0) }
                    ),
                    range: widthRange
                )
                dimensionControl(
                    title: "Height",
                    symbol: "arrow.up.and.down",
                    value: Binding(
                        get: { bounds.height },
                        set: { setHeight($0) }
                    ),
                    range: heightRange
                )
            }
        } else {
            HStack(spacing: PPSpacing.medium) {
                dimensionControl(
                    title: "Width",
                    symbol: "arrow.left.and.right",
                    value: Binding(
                        get: { bounds.width },
                        set: { setWidth($0) }
                    ),
                    range: widthRange
                )
                dimensionControl(
                    title: "Height",
                    symbol: "arrow.up.and.down",
                    value: Binding(
                        get: { bounds.height },
                        set: { setHeight($0) }
                    ),
                    range: heightRange
                )
            }
        }
    }

    private func dimensionControl(
        title: String,
        symbol: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Label(title.localizedUI, systemImage: symbol)
                .font(.caption)
                .frame(minWidth: 62, alignment: .leading)
            Slider(value: value, in: range)
        }
        .foregroundStyle(PPColor.textSecondary)
        .accessibilityElement(children: .contain)
    }

    private var widthRange: ClosedRange<Double> {
        kind == .checkbox
            ? 0.08...0.14
            : 0.18...0.82
    }

    private var heightRange: ClosedRange<Double> {
        kind == .checkbox
            ? 0.04...0.14
            : 0.04...0.42
    }

    private var controlsMaximumHeight: CGFloat {
        if verticalSizeClass == .compact {
            return 230
        }
        return dynamicTypeSize.ppPrefersExpandedLayout ? 380 : 330
    }

    private var pageStepper: some View {
        HStack(spacing: PPSpacing.small) {
            Button {
                pageIndex = max(0, pageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(pageIndex == 0)
            .accessibilityLabel("Previous form page")
            Text(
                AppLocalization.format(
                    "Page %lld",
                    pageIndex + 1
                )
            )
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Button {
                pageIndex = min(maxPageIndex, pageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(pageIndex >= maxPageIndex)
            .accessibilityLabel("Next form page")
        }
    }

    private var maxPageIndex: Int {
        max(0, (model.record(id: recordID)?.profile.pageCount ?? 1) - 1)
    }

    private var canAdd: Bool {
        pagePreview != nil
            && previewContentRevisionID == contentRevisionID
            && model.record(id: recordID)?.contentRevisionID == contentRevisionID
            && previewErrorMessage == nil
            && !isLoadingPagePreview
            && isSafeSingleLine(
            fieldName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            maximumCharacters: 80,
            maximumBytes: 512
        )
            && (
                kind != .radio && kind != .choice
                    || validOptions
            )
            && overlappingFields.isEmpty
    }

    private var hasDraftChanges: Bool {
        guard !didCommitField else { return false }
        return pageIndex != initialPageIndexValue
            || kind != .text
            || !fieldName.isEmpty
            || isRequired
            || isMultiline
            || maximumLength != 0
            || optionsText != "Option 1\nOption 2"
            || isListChoice
            || bounds != initialBounds
    }

    private var addFieldAccessibilityHint: String {
        if isSaving || model.isProcessing(recordID) {
            return "Wait for the current PDF operation to finish."
                .localizedUI
        }
        if pagePreview == nil || isLoadingPagePreview {
            return "Wait for the page preview to finish."
                .localizedUI
        }
        if !isSafeSingleLine(
            fieldName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            maximumCharacters: 80,
            maximumBytes: 512
        ) {
            return "Enter a valid field name.".localizedUI
        }
        if (kind == .radio || kind == .choice), !validOptions {
            return "Enter 2 to 12 unique field options."
                .localizedUI
        }
        if !overlappingFields.isEmpty {
            return "Move the field away from existing fields."
                .localizedUI
        }
        return "Adds this field to the private working copy."
            .localizedUI
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
            && options.allSatisfy {
                isSafeSingleLine(
                    $0,
                    maximumCharacters: 64,
                    maximumBytes: 256
                )
            }
            && Set(options.map {
                $0.folding(
                    options: [
                        .caseInsensitive,
                        .diacriticInsensitive,
                        .widthInsensitive
                    ],
                    locale: .current
                )
            }).count
                == options.count
    }

    private func isSafeSingleLine(
        _ value: String,
        maximumCharacters: Int,
        maximumBytes: Int
    ) -> Bool {
        guard !value.isEmpty,
              value.count <= maximumCharacters,
              value.utf8.count <= maximumBytes
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                (0x202A...0x202E).contains(codePoint)
                    || (0x2066...0x2069).contains(codePoint)
            return !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && !isBidirectionalControl
        }
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
        guard canAdd,
              !isSaving,
              !didCommitField,
              !model.isProcessing(recordID),
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        saveErrorMessage = nil
        isSaving = true
        saveStopRequested = false
        didCommitField = false
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
        let generation = UUID()
        saveGeneration = generation
        saveTask = Task {
            let succeeded = await model.withFeedbackTarget(paperPathSceneID) {
                await model.addFormField(
                    recordID: recordID,
                    payload: payload,
                    expectedContentRevisionID: contentRevisionID
                )
            }
            guard saveGeneration == generation else { return }
            let wasStopped =
                saveStopRequested || Task.isCancelled
            didCommitField = succeeded
            isSaving = false
            saveTask = nil
            saveStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    succeeded
                        ? "Update finished before stopping · changes kept"
                        : "Form field creation stopped"
                ).localizedUI
                if succeeded {
                    didCommitField = true
                    onCommitted()
                }
                return
            }
            guard succeeded else {
                saveErrorMessage =
                    "The field could not be added. Try again."
                        .localizedUI
                saveErrorFeedback += 1
                return
            }
            onCreated()
        }
    }

    private func requestDismiss() {
        if hasDraftChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func resizeForKind(
        _ kind: PDFFormFieldKind
    ) {
        let size: (Double, Double)
        switch kind {
        case .checkbox:
            size = (0.08, 0.058)
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
        previewGeneration += 1
        let generation = previewGeneration
        let selectedPage = pageIndex
        let revision = model.refreshToken(for: recordID)
        pagePreview = nil
        previewContentRevisionID = nil
        previewErrorMessage = nil
        isLoadingPagePreview = true
        guard model.record(id: recordID)?.contentRevisionID == contentRevisionID,
              let url = model.url(for: recordID) else {
            guard generation == previewGeneration else { return }
            isLoadingPagePreview = false
            previewErrorMessage =
                "The working copy is unavailable."
            return
        }
        let preview = await PDFEditorPreviewLoader.shared.preview(
            url: url,
            pageIndex: selectedPage,
            revision: revision
        )
        guard !Task.isCancelled,
              generation == previewGeneration,
              pageIndex == selectedPage,
              model.record(id: recordID)?.contentRevisionID == contentRevisionID,
              model.refreshToken(for: recordID) == revision
        else { return }
        isLoadingPagePreview = false
        guard let preview else {
            previewErrorMessage =
                "The page preview could not be loaded. Try again."
            return
        }
        pagePreview = preview.image
        previewContentRevisionID = contentRevisionID
        pageAspectRatio = CGFloat(preview.aspectRatio)
    }

    private func retryPagePreview() {
        pagePreview = nil
        previewContentRevisionID = nil
        previewErrorMessage = nil
        isLoadingPagePreview = true
        previewReloadToken = UUID()
    }

    private var pagePreviewRequestID: String {
        "\(pageIndex)-\(model.refreshToken(for: recordID))-\(previewReloadToken)"
    }

    private func interruptProtectedFieldWork() {
        previewGeneration += 1
        stopFieldSave(invalidateResult: true)
        pagePreview = nil
        previewContentRevisionID = nil
        previewErrorMessage = nil
        isLoadingPagePreview = false
    }

    private func interruptProtectedFieldEditing() {
        interruptProtectedFieldWork()
        fieldName = ""
        optionsText = ""
        dismiss()
    }

    private func stopFieldSave(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            saveGeneration = UUID()
            saveStopRequested = false
        } else {
            guard saveTask != nil,
                  !saveStopRequested
            else { return }
            saveStopRequested = true
        }
        saveTask?.cancel()
        if invalidateResult {
            saveTask = nil
            isSaving = false
        }
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
