import SwiftUI

struct DocumentInsightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let record: DocumentRecord
    let onAction: (DocumentAction) -> Void
    @State private var selectedRecommendation: DocumentAction?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                ScrollView {
                    VStack(alignment: .leading, spacing: PPSpacing.large) {
                        summary
                        if !actionableRecommendations.isEmpty {
                            recommendations
                        }
                        privacy
                    }
                    .frame(maxWidth: 880)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Document details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .accessibilityAction(.escape) {
            dismiss()
        }
        .sensoryFeedback(.selection, trigger: selectedRecommendation)
    }

    private var summary: some View {
        WorkflowCommandHeader(
            eyebrow: "ABOUT THIS PDF",
            title: record.profile.kind.title,
            detail: record.profile.summary,
            symbol: record.profile.kind.symbol,
            tint: PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(record.profile.pageCount)",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: record.profile.formattedSize,
                    label: "Private copy",
                    symbol: "internaldrive",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: "\(record.profile.formFieldCount)",
                    label: "Form fields",
                    symbol: "list.bullet.clipboard",
                    tint: PPColor.mint
                )
            ]
        )
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "SUGGESTED NEXT STEPS")
            VStack(spacing: 0) {
                ForEach(
                    Array(actionableRecommendations.enumerated()),
                    id: \.element.id
                ) { index, action in
                    let isSelected = selectedRecommendation == action
                    Button {
                        guard selectedRecommendation == nil else { return }
                        selectedRecommendation = action
                        onAction(action)
                    } label: {
                        HStack(alignment: .top, spacing: PPSpacing.medium) {
                            Image(systemName: action.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(
                                    isSelected ? PPColor.mint : PPColor.accent
                                )
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(action.title.localizedUI)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(PPColor.textPrimary)
                                Text(action.explanation.localizedUI)
                                    .font(.caption)
                                    .foregroundStyle(PPColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(
                                systemName: isSelected
                                    ? "checkmark.circle.fill"
                                    : "chevron.right"
                            )
                                .font(.caption.weight(.bold))
                                .foregroundStyle(
                                    isSelected ? PPColor.mint : PPColor.textSecondary
                                )
                                .frame(minHeight: 28)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedRecommendation != nil)
                    .opacity(
                        selectedRecommendation == nil || isSelected ? 1 : 0.48
                    )
                    .accessibilityHint("Opens this action".localizedUI)
                    .padding(.vertical, PPSpacing.medium)

                    if index < actionableRecommendations.count - 1 {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.68))
                            .frame(height: 0.6)
                            .padding(.leading, 44)
                    }
                }
            }
            .padding(.horizontal, PPSpacing.medium)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.65))
                    .frame(height: 0.6)
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "PRIVACY")
            VStack(alignment: .leading, spacing: PPSpacing.medium) {
                evidence(
                    "Processing",
                    value: "On this device",
                    symbol: "iphone.gen3"
                )
                evidence(
                    "Network upload",
                    value: "None",
                    symbol: "icloud.slash"
                )
                evidence(
                    "Original file",
                    value: "Untouched",
                    symbol: "doc.badge.ellipsis"
                )
                evidence(
                    "Copy permission",
                    value: record.profile.allowsCopying ? "Allowed" : "Restricted",
                    symbol: "doc.on.doc"
                )
            }
            .padding(.vertical, PPSpacing.small)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.65))
                    .frame(height: 0.6)
            }
        }
    }

    private func evidence(
        _ title: String,
        value: String,
        symbol: String
    ) -> some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(alignment: .leading, spacing: 3) {
                    Label(title.localizedUI, systemImage: symbol)
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textSecondary)
                    Text(value.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack {
                    Label(title.localizedUI, systemImage: symbol)
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textSecondary)
                    Spacer()
                    Text(value.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var actionableRecommendations: [DocumentAction] {
        record.profile.recommendedActions.filter {
            $0 != .inspect && $0 != .brief
        }
    }
}

private struct PDFPagePairingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let sourceURL: URL
    let revisedURL: URL
    let sourceLabel: String
    let sourceTitle: String
    let revisedTitle: String
    let sourcePageIndex: Int
    let sourcePageCount: Int
    let revisedPageCount: Int
    let allowedRevisedRange: ClosedRange<Int>
    let revisedRefreshToken: Int
    let hasExistingCorrection: Bool
    let initialRevisedPageNumber: Int
    let onApply: (Int) -> Void
    let onReset: (() -> Void)?

    @State private var revisedPageNumber: Int
    @State private var isConfirmingDiscard = false
    @FocusState private var isPageFieldFocused: Bool

    init(
        sourceURL: URL,
        revisedURL: URL,
        sourceLabel: String,
        sourceTitle: String,
        revisedTitle: String,
        sourcePageIndex: Int,
        revisedPageIndex: Int,
        sourcePageCount: Int,
        revisedPageCount: Int,
        allowedRevisedRange: ClosedRange<Int>,
        revisedRefreshToken: Int,
        hasExistingCorrection: Bool,
        onApply: @escaping (Int) -> Void,
        onReset: (() -> Void)?
    ) {
        self.sourceURL = sourceURL
        self.revisedURL = revisedURL
        self.sourceLabel = sourceLabel
        self.sourceTitle = sourceTitle
        self.revisedTitle = revisedTitle
        self.sourcePageIndex = sourcePageIndex
        self.sourcePageCount = sourcePageCount
        self.revisedPageCount = revisedPageCount
        self.allowedRevisedRange = allowedRevisedRange
        self.revisedRefreshToken = revisedRefreshToken
        self.hasExistingCorrection = hasExistingCorrection
        initialRevisedPageNumber = revisedPageIndex + 1
        self.onApply = onApply
        self.onReset = onReset
        _revisedPageNumber = State(
            initialValue: revisedPageIndex + 1
        )
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
                        pairingHeader
                        previewPair
                        revisedPageControl
                    }
                    .frame(maxWidth: 620)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Correct Page Match".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".localizedUI) {
                        requestDismissal()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isPageFieldFocused = false
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionBar
            }
        }
        .presentationDetents(
            dynamicTypeSize.ppPrefersExpandedLayout
                ? [.large]
                : [.medium, .large]
        )
        .confirmationDialog(
            "Discard page match change?".localizedUI,
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(
                "Discard Page Match Change".localizedUI,
                role: .destructive
            ) {
                dismiss()
            }
            Button("Keep Editing".localizedUI, role: .cancel) {}
        } message: {
            Text(
                "The selected page match has not been applied."
                    .localizedUI
            )
        }
        .interactiveDismissDisabled(hasDraftChanges)
        .accessibilityAction(.escape) {
            if isPageFieldFocused {
                isPageFieldFocused = false
            } else {
                requestDismissal()
            }
        }
        .sensoryFeedback(.selection, trigger: revisedPageNumber)
    }

    private var pairingHeader: some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            Label(
                AppLocalization.format(
                    "Match %@ page %lld",
                    sourceLabel.localizedUI,
                    sourcePageIndex + 1
                ),
                systemImage: "arrow.left.arrow.right"
            )
            .font(.headline)
            .foregroundStyle(PPColor.textPrimary)
            Text(
                "Choose the current page that represents the same document position."
                    .localizedUI
            )
            .font(.subheadline)
            .foregroundStyle(PPColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previewPair: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: PPSpacing.large) {
                pagePreview(
                    label: "SAVED",
                    title: sourceTitle,
                    url: sourceURL,
                    pageIndex: sourcePageIndex,
                    pageCount: sourcePageCount,
                    refreshToken: 0,
                    tint: PPColor.cyan
                )
                pagePreview(
                    label: "CURRENT",
                    title: revisedTitle,
                    url: revisedURL,
                    pageIndex: selectedRevisedPageIndex,
                    pageCount: revisedPageCount,
                    refreshToken: revisedRefreshToken,
                    tint: PPColor.amber
                )
            }
            VStack(spacing: PPSpacing.medium) {
                pagePreview(
                    label: "SAVED",
                    title: sourceTitle,
                    url: sourceURL,
                    pageIndex: sourcePageIndex,
                    pageCount: sourcePageCount,
                    refreshToken: 0,
                    tint: PPColor.cyan
                )
                pagePreview(
                    label: "CURRENT",
                    title: revisedTitle,
                    url: revisedURL,
                    pageIndex: selectedRevisedPageIndex,
                    pageCount: revisedPageCount,
                    refreshToken: revisedRefreshToken,
                    tint: PPColor.amber
                )
            }
        }
    }

    private func pagePreview(
        label: String,
        title: String,
        url: URL,
        pageIndex: Int,
        pageCount: Int,
        refreshToken: Int,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            PDFPageThumbnailView(
                url: url,
                pageIndex: pageIndex,
                refreshToken: refreshToken,
                width: 92
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(label.localizedUI)
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(2)
                Text(
                    AppLocalization.format(
                        "Page %lld of %lld",
                        pageIndex + 1,
                        pageCount
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var revisedPageControl: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Text("CURRENT PAGE")
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(PPColor.textSecondary)
            if dynamicTypeSize.ppPrefersExpandedLayout {
                Text(
                    AppLocalization.format(
                        "Page %lld of %lld",
                        revisedPageNumber,
                        revisedPageCount
                    )
                )
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)

                HStack(spacing: PPSpacing.small) {
                    previousRevisedPageButton
                    revisedPageField
                        .frame(maxWidth: 140)
                    nextRevisedPageButton
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    previousRevisedPageButton
                    revisedPageField
                        .frame(width: 82)
                    Text(
                        AppLocalization.format(
                            "of %lld",
                            revisedPageCount
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    nextRevisedPageButton
                    Spacer(minLength: 0)
                }
            }

            if !isValidSelection {
                Label(
                    AppLocalization.format(
                        "Choose a page from %lld to %lld",
                        minimumRevisedPageNumber,
                        maximumRevisedPageNumber
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
            } else {
                Label(
                    allowedPageRangeDescription,
                    systemImage: "arrow.up.and.down.text.horizontal"
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var previousRevisedPageButton: some View {
        Button {
            revisedPageNumber -= 1
        } label: {
            Image(systemName: "minus")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .disabled(
            revisedPageNumber <= minimumRevisedPageNumber
        )
        .accessibilityLabel("Previous current page")
    }

    private var revisedPageField: some View {
        TextField(
            "Page".localizedUI,
            value: $revisedPageNumber,
            format: .number
        )
        .keyboardType(.numberPad)
        .focused($isPageFieldFocused)
        .multilineTextAlignment(.center)
        .font(.body.monospacedDigit().weight(.semibold))
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Current page number")
        .accessibilityValue(
            AppLocalization.format(
                "Page %lld, allowed range %lld to %lld",
                revisedPageNumber,
                minimumRevisedPageNumber,
                maximumRevisedPageNumber
            )
        )
    }

    private var nextRevisedPageButton: some View {
        Button {
            revisedPageNumber += 1
        } label: {
            Image(systemName: "plus")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .disabled(
            revisedPageNumber >= maximumRevisedPageNumber
        )
        .accessibilityLabel("Next current page")
    }

    private var actionBar: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(spacing: PPSpacing.small) {
                    resetPairingButton
                    applyPairingButton
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    resetPairingButton
                    Spacer(minLength: 0)
                    applyPairingButton
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

    @ViewBuilder
    private var resetPairingButton: some View {
        if hasExistingCorrection, let onReset {
            Button {
                onReset()
            } label: {
                Label(
                    "Use Automatic",
                    systemImage: "arrow.counterclockwise"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
            .accessibilityHint(
                "Removes this manual match and recalculates automatically."
                    .localizedUI
            )
        }
    }

    private var applyPairingButton: some View {
        Button {
            let revisedPageIndex = selectedRevisedPageIndex
            onApply(revisedPageIndex)
        } label: {
            Label("Use Match", systemImage: "checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(!isValidSelection)
        .keyboardShortcut(.defaultAction)
        .accessibilityHint(pairingApplyHint)
    }

    private var minimumRevisedPageNumber: Int {
        allowedRevisedRange.lowerBound + 1
    }

    private var maximumRevisedPageNumber: Int {
        allowedRevisedRange.upperBound + 1
    }

    private var isValidSelection: Bool {
        (minimumRevisedPageNumber...maximumRevisedPageNumber)
            .contains(revisedPageNumber)
    }

    private var allowedPageRangeDescription: String {
        if minimumRevisedPageNumber == maximumRevisedPageNumber {
            return AppLocalization.format(
                "Page %lld is the only ordered match available.",
                minimumRevisedPageNumber
            )
        }
        return AppLocalization.format(
            "Pages %lld to %lld preserve the saved page order.",
            minimumRevisedPageNumber,
            maximumRevisedPageNumber
        )
    }

    private var pairingApplyHint: String {
        guard isValidSelection else {
            return AppLocalization.format(
                "Choose a page from %lld to %lld.",
                minimumRevisedPageNumber,
                maximumRevisedPageNumber
            )
        }
        return "Saves this page match locally and recalculates the comparison."
            .localizedUI
    }

    private var selectedRevisedPageIndex: Int {
        min(
            allowedRevisedRange.upperBound,
            max(
                allowedRevisedRange.lowerBound,
                revisedPageNumber - 1
            )
        )
    }

    private var hasDraftChanges: Bool {
        revisedPageNumber != initialRevisedPageNumber
    }

    private func requestDismissal() {
        isPageFieldFocused = false
        if hasDraftChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }
}

private struct PDFTechnicalInspectionRequestID: Hashable {
    let recordID: UUID
    let refreshToken: Int
    let isSceneActive: Bool
    let passwordGeneration: UUID
}

struct PDFTechnicalInspectorView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    let recordID: UUID
    let unlockPassword: String?

    @State private var inspection: PDFTechnicalInspection?
    @State private var isLoading = true
    @State private var loadGeneration = 0
    @State private var passwordGeneration = UUID()

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
                            hero(record)
                            if let inspection {
                                overview(inspection)
                                inspectorEvidence(
                                    inspection,
                                    record: record
                                )
                            } else if isLoading {
                                HStack(spacing: PPSpacing.small) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Inspecting PDF")
                                        .font(
                                            .caption.weight(.semibold)
                                        )
                                    Spacer()
                                    OnDeviceBadge(compact: true)
                                }
                                .frame(minHeight: 40)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(
                                            PPColor.border.opacity(0.62)
                                        )
                                        .frame(height: 0.6)
                                }
                            } else if !isLoading {
                                VStack(spacing: PPSpacing.medium) {
                                    ContentUnavailableView(
                                        "Inspection unavailable",
                                        systemImage: "doc.badge.ellipsis",
                                        description: Text(
                                            "The private working copy could not be inspected."
                                        )
                                    )
                                    Button {
                                        Task { await reload() }
                                    } label: {
                                        Label(
                                            "Inspect Again",
                                            systemImage: "arrow.clockwise"
                                        )
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(PPPrimaryButtonStyle())
                                    .accessibilityIdentifier(
                                        "retryTechnicalInspection"
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: 1_080)
                        .padding(PPSpacing.regular)
                        .padding(.bottom, PPSpacing.section)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView(
                        "Document unavailable",
                        systemImage: "doc.questionmark"
                    )
                }
            }
            .navigationTitle("Technical Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .task(id: inspectionRequestID) {
                guard scenePhase == .active else { return }
                await reload()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                clearInspection()
            }
            .onChange(of: unlockPassword) {
                passwordGeneration = UUID()
                clearInspection()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            clearInspection()
            dismiss()
        }
        .onDisappear {
            clearInspection()
        }
        .accessibilityAction(.escape) {
            clearInspection()
            dismiss()
        }
    }

    private var inspectionRequestID: PDFTechnicalInspectionRequestID {
        PDFTechnicalInspectionRequestID(
            recordID: recordID,
            refreshToken: model.refreshToken(for: recordID),
            isSceneActive: scenePhase == .active,
            passwordGeneration: passwordGeneration
        )
    }

    private func clearInspection() {
        loadGeneration &+= 1
        inspection = nil
        isLoading = false
    }

    @ViewBuilder
    private func hero(_ record: DocumentRecord) -> some View {
        WorkflowCommandHeader(
            eyebrow: "TECHNICAL EVIDENCE",
            title: record.displayName,
            detail: inspection?.isLocked == true
                ? "Structure requires the document password."
                : "Structure and permissions inspected on this device.",
            symbol: inspection?.isLocked == true
                ? "lock.doc"
                : "doc.text.magnifyingglass",
            tint: inspection?.isLocked == true
                ? PPColor.amber
                : PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(inspection?.pageCount ?? record.profile.pageCount)",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: inspection?.isLocked == true
                        ? "Locked"
                        : "Readable",
                    label: "Access",
                    symbol: inspection?.isLocked == true
                        ? "lock.fill"
                        : "checkmark.circle",
                    tint: inspection?.isLocked == true
                        ? PPColor.amber
                        : PPColor.mint
                ),
                WorkflowMetric(
                    value: "\(structureObjectCount)",
                    label: "Objects",
                    symbol: "shippingbox",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: String(
                        record.contentRevisionID.uuidString.prefix(8)
                    ),
                    label: "Revision",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: PPColor.textSecondary
                )
            ]
        )
    }

    @ViewBuilder
    private func inspectorEvidence(
        _ report: PDFTechnicalInspection,
        record: DocumentRecord
    ) -> some View {
        if horizontalSizeClass == .regular,
           !dynamicTypeSize.ppPrefersExpandedLayout {
            HStack(alignment: .top, spacing: PPSpacing.large) {
                structure(report)
                    .frame(maxWidth: .infinity, alignment: .top)
                security(report)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            HStack(alignment: .top, spacing: PPSpacing.large) {
                source(report)
                    .frame(maxWidth: .infinity, alignment: .top)
                identity(record)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            structure(report)
            security(report)
            source(report)
            identity(record)
        }
    }

    private var structureObjectCount: Int {
        guard let inspection else { return 0 }
        return (inspection.annotationCount ?? 0)
            + (inspection.attachmentCount ?? 0)
            + (inspection.outlineEntryCount ?? 0)
            + (inspection.formFieldCount ?? 0)
    }

    private var heroSymbol: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PPColor.surfaceMuted)
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title.weight(.semibold))
                .foregroundStyle(
                    inspection?.isLocked == true
                        ? PPColor.amber
                        : PPColor.cyan
                )
        }
        .frame(width: 76, height: 76)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(PPColor.border.opacity(0.72), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    private func heroCopy(_ record: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            SectionEyebrow(text: "CURRENT WORKING COPY")
            Text(record.displayName)
                .font(.title2.bold())
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(2)
            Label(
                inspection?.isLocked == true
                    ? "Structure requires document password"
                    : "Structure inspected on device",
                systemImage: inspection?.isLocked == true
                    ? "lock.fill"
                    : "checkmark.shield.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(
                inspection?.isLocked == true
                    ? PPColor.amber
                    : PPColor.mint
            )
        }
    }

    private func overview(
        _ report: PDFTechnicalInspection
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "DOCUMENT")
            LazyVGrid(
                columns: dynamicTypeSize.ppPrefersExpandedLayout
                    ? [GridItem(.flexible())]
                    : [
                        GridItem(
                            .flexible(),
                            spacing: PPSpacing.medium
                        ),
                        GridItem(
                            .flexible(),
                            spacing: PPSpacing.medium
                        )
                    ],
                spacing: PPSpacing.medium
            ) {
                metric(
                    value: "\(report.pageCount)",
                    label: "Pages",
                    symbol: "doc.on.doc"
                )
                metric(
                    value: ByteCountFormatter.string(
                        fromByteCount: report.byteCount,
                        countStyle: .file
                    ),
                    label: "File size",
                    symbol: "internaldrive"
                )
                metric(
                    value: report.textCoverage.map {
                        "\(Int(($0 * 100).rounded()))%"
                    } ?? "—",
                    label: report.sampledPageCount > 0
                        ? AppLocalization.format(
                            "%@ · %lld sampled",
                            "Text coverage".localizedUI,
                            report.sampledPageCount
                        )
                        : "Text coverage",
                    symbol: "textformat"
                )
                metric(
                    value: technicalValue(report.formFieldCount),
                    label: "Form fields",
                    symbol: "list.bullet.clipboard"
                )
            }
        }
    }

    private func structure(
        _ report: PDFTechnicalInspection
    ) -> some View {
        technicalSection(title: "PDF STRUCTURE") {
            technicalRow(
                title: "Annotations",
                value: technicalValue(report.annotationCount),
                symbol: "text.bubble",
                tint: PPColor.amber
            )
            technicalRow(
                title: "Embedded files",
                value: technicalValue(report.attachmentCount),
                symbol: "paperclip",
                tint: PPColor.cyan
            )
            technicalRow(
                title: "Outline entries",
                value: technicalValue(report.outlineEntryCount),
                symbol: "list.bullet.indent",
                tint: PPColor.accent
            )
            technicalRow(
                title: "Explicit page labels",
                value: report.hasExplicitPageLabels.map {
                    $0 ? "Present" : "None"
                } ?? "Requires unlock",
                symbol: "number.square",
                tint: PPColor.mint
            )
            technicalRow(
                title: "Image-dominant pages",
                value: report.imageDominantPageCount.map {
                    AppLocalization.format(
                        "%lld of %lld sampled",
                        $0,
                        report.sampledPageCount
                    )
                } ?? "Not sampled",
                symbol: "photo.on.rectangle",
                tint: PPColor.cyan
            )
        }
    }

    private func security(
        _ report: PDFTechnicalInspection
    ) -> some View {
        technicalSection(title: "SECURITY & PERMISSIONS") {
            technicalRow(
                title: "Encryption",
                value: report.isEncrypted ? "Encrypted" : "Not encrypted",
                symbol: report.isEncrypted ? "lock.fill" : "lock.open",
                tint: report.isEncrypted ? PPColor.amber : PPColor.mint
            )
            technicalRow(
                title: "Current access",
                value: report.isLocked ? "Locked" : "Readable now",
                symbol: report.isLocked
                    ? "key.slash"
                    : "checkmark.circle",
                tint: report.isLocked ? PPColor.amber : PPColor.mint
            )
            permissionRow(
                "Copy content",
                allowed: report.permissions?.allowsCopying,
                symbol: "doc.on.doc"
            )
            permissionRow(
                "Comment",
                allowed: report.permissions?.allowsCommenting,
                symbol: "text.bubble"
            )
            permissionRow(
                "Fill forms",
                allowed: report.permissions?.allowsFormFilling,
                symbol: "rectangle.and.pencil.and.ellipsis"
            )
            permissionRow(
                "Assemble pages",
                allowed: report.permissions?.allowsDocumentAssembly,
                symbol: "square.grid.2x2"
            )
            permissionRow(
                "High-quality print",
                allowed: report.permissions?.allowsHighQualityPrinting,
                symbol: "printer"
            )
            permissionRow(
                "Accessibility extraction",
                allowed: report.permissions?
                    .allowsContentAccessibility,
                symbol: "accessibility"
            )
        }
    }

    private func source(
        _ report: PDFTechnicalInspection
    ) -> some View {
        technicalSection(title: "SOURCE") {
            technicalRow(
                title: "Files original",
                value: report.source?.status.title
                    ?? "Status unavailable",
                symbol: report.source?.status.symbol
                    ?? "folder.badge.questionmark",
                tint: sourceTint(report.source?.status)
            )
            if let name = report.source?.name {
                technicalRow(
                    title: "Source name",
                    value: name,
                    symbol: "doc"
                )
            }
            if report.source?.isUbiquitous == true {
                technicalRow(
                    title: "Source provider",
                    value: "iCloud Drive",
                    symbol: "icloud",
                    tint: PPColor.cyan
                )
            }
            if let modifiedAt = report.source?.modificationDate {
                technicalRow(
                    title: "Source modified",
                    value: modifiedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ),
                    symbol: "clock"
                )
            }
        }
    }

    private func identity(_ record: DocumentRecord) -> some View {
        technicalSection(title: "LOCAL IDENTITY") {
            technicalRow(
                title: "Revision",
                value: String(
                    record.contentRevisionID.uuidString.prefix(12)
                ),
                symbol: "point.3.connected.trianglepath.dotted"
            )
            technicalRow(
                title: "SHA-256",
                value: record.contentFingerprint.map {
                    groupedFingerprint(String($0.prefix(16)))
                } ?? "Pending",
                symbol: "number"
            )
            technicalRow(
                title: "File protection",
                value: "Complete",
                symbol: "lock.shield.fill",
                tint: PPColor.mint
            )
        }
    }

    private func metric(
        value: String,
        label: String,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.cyan)
                .dynamicTypeSize(.xSmall ... .accessibility1)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout ? nil : 1
                )
                .fixedSize(horizontal: false, vertical: true)
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout ? nil : 2
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.6))
                .frame(height: 0.6)
        }
    }

    private func technicalSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: title)
            VStack(spacing: 0) {
                content()
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.66))
                    .frame(height: 0.6)
            }
        }
    }

    private func technicalRow(
        title: String,
        value: String,
        symbol: String,
        tint: Color = PPColor.textSecondary
    ) -> some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                HStack(
                    alignment: .top,
                    spacing: PPSpacing.medium
                ) {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .dynamicTypeSize(.xSmall ... .accessibility1)
                        .frame(width: 24)
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xSmall
                    ) {
                        Text(title.localizedUI)
                            .font(.subheadline)
                            .foregroundStyle(PPColor.textSecondary)
                        Text(value.localizedUI)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(
                    alignment: .firstTextBaseline,
                    spacing: PPSpacing.medium
                ) {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24)
                    Text(title.localizedUI)
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textSecondary)
                    Spacer(minLength: PPSpacing.medium)
                    Text(value.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.5))
                .frame(height: 0.6)
                .padding(.leading, 40)
        }
        .accessibilityElement(children: .combine)
    }

    private func permissionRow(
        _ title: String,
        allowed: Bool?,
        symbol: String
    ) -> some View {
        technicalRow(
            title: title,
            value: allowed.map { $0 ? "Allowed" : "Restricted" }
                ?? "Requires unlock",
            symbol: symbol,
            tint: allowed == false ? PPColor.amber : PPColor.textSecondary
        )
    }

    private func technicalValue(_ value: Int?) -> String {
        value.map(String.init) ?? "Requires unlock"
    }

    private func sourceTint(
        _ status: PDFSourceLocationStatus?
    ) -> Color {
        switch status {
        case .current: return PPColor.mint
        case .changed, .stale: return PPColor.amber
        case .unavailable: return .red
        case .detached, nil: return PPColor.textSecondary
        }
    }

    private func groupedFingerprint(_ value: String) -> String {
        value.enumerated().reduce(into: "") { result, pair in
            if pair.offset > 0, pair.offset.isMultiple(of: 4) {
                result.append(" ")
            }
            result.append(pair.element)
        }
    }

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        let report = await model.technicalInspection(
            recordID: recordID,
            unlockPassword: unlockPassword
        )
        guard !Task.isCancelled,
              generation == loadGeneration
        else { return }
        inspection = report
        isLoading = false
    }
}

struct PDFVersionHistoryView: View {
    private struct RevisionProofPayload: Identifiable {
        let version: PDFVersionSnapshot
        let historicalURL: URL
        let revisedRevisionID: UUID
        let revisedTitle: String
        let revisedURL: URL
        let revisedPageCount: Int
        let revisedRefreshToken: Int
        let review: PDFChangeReview

        var id: UUID { version.id }
    }

    private struct PendingReceiptPageOpen {
        let recordID: UUID
        let pageIndex: Int
        let contentRevisionID: UUID
    }

    private struct VersionReloadTaskID: Hashable {
        let isActive: Bool
        let evidenceRevision: Int
        let contentRevisionID: UUID?
        let request: Int
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let initialVersionID: UUID?
    let onOpenPage: ((UUID, Int) -> Void)?

    @State private var versions: [PDFVersionSnapshot] = []
    @State private var selectedVersion: PDFVersionSnapshot?
    @State private var inspectedVersion: PDFVersionSnapshot?
    @State private var inspectedVersionURL: URL?
    @State private var comparisonReview: PDFChangeReview?
    @State private var comparisonError: String?
    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @State private var loadErrorFeedback = 0
    @State private var reloadRequest = 0
    @State private var protectedDataAvailable =
        UIApplication.shared.isProtectedDataAvailable
    @State private var isRestoring = false
    @State private var restoreStopRequested = false
    @State private var isComparing = false
    @State private var comparisonProgress =
        PDFComparisonProgress.starting
    @State private var loadGeneration = 0
    @State private var restoreTask: Task<Void, Never>?
    @State private var restoreGeneration = UUID()
    @State private var comparisonTask: Task<Void, Never>?
    @State private var comparisonGeneration = 0
    @State private var revisionProof: RevisionProofPayload?
    @State private var editingMilestone: PDFVersionSnapshot?
    @State private var linkedReceiptVersion: PDFVersionSnapshot?
    @State private var appliedInitialVersion = false
    @State private var pinnedStorageSummary =
        PDFPinnedVersionStorageSummary.empty
    @State private var hasLoadedPinnedStorageSummary = false
    @State private var versionArchiveURL: URL?
    @State private var isSharingVersionArchive = false
    @State private var isCreatingVersionArchive = false
    @State private var versionArchiveTask: Task<Void, Never>?
    @State private var versionArchiveGeneration = UUID()
    @State private var versionArchiveProgress: PDFOperationProgress?
    @State private var versionArchiveRateWindow = ByteRateWindow()
    @State private var changeReportURL: URL?
    @State private var isSharingChangeReport = false
    @State private var changeReportTask: Task<Void, Never>?
    @State private var changeReportGeneration = UUID()
    @State private var changeReportShareCount = 0
    @State private var pinnedStorageTask: Task<Void, Never>?
    @State private var pinnedStorageGeneration = UUID()
    @State private var pendingReceiptPageOpen:
        PendingReceiptPageOpen?
    @State private var receiptPageNavigationTask:
        Task<Void, Never>?
    @State private var receiptPageNavigationGeneration = UUID()

    init(
        recordID: UUID,
        initialVersionID: UUID? = nil,
        onOpenPage: ((UUID, Int) -> Void)? = nil
    ) {
        self.recordID = recordID
        self.initialVersionID = initialVersionID
        self.onOpenPage = onOpenPage
    }

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
                            hero(record)
                            OfficeClockContinuitySection()
                            currentSummary(record)
                            if let inspectedVersion {
                                revisionBench(
                                    inspectedVersion,
                                    current: record
                                )
                                LinkedChangeReportSection(
                                    lookup: .versionSnapshot(
                                        recordID: record.id,
                                        snapshotID:
                                            inspectedVersion.id
                                    )
                                )
                            }
                            history(record)
                        }
                        .frame(maxWidth: 880)
                        .padding(PPSpacing.regular)
                        .padding(.bottom, PPSpacing.section)
                        .frame(maxWidth: .infinity)
                    }
                    .refreshable {
                        await reload()
                    }
                } else {
                    ContentUnavailableView(
                        "Document unavailable",
                        systemImage: "doc.questionmark"
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isCreatingVersionArchive,
                   let versionArchiveProgress {
                    HStack(spacing: PPSpacing.small) {
                        LocalOperationProgressView(
                            progress: versionArchiveProgress
                        )
                        Button {
                            stopVersionArchiveCreation()
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PPColor.amber)
                        .accessibilityLabel("Stop archiving milestones")
                    }
                    .padding(.horizontal, PPSpacing.regular)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.62))
                            .frame(height: 0.6)
                    }
                } else if changeReportTask != nil {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing change report".localizedUI)
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Button {
                            stopChangeReportCreation()
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PPColor.amber)
                        .accessibilityLabel("Stop preparing change report")
                    }
                    .padding(.horizontal, PPSpacing.regular)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.62))
                            .frame(height: 0.6)
                    }
                } else if isComparing {
                    HStack(spacing: PPSpacing.small) {
                        LocalComparisonProgressView(
                            progress: comparisonProgress,
                            compact: true
                        )
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        Button {
                            stopComparison()
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PPColor.cyan)
                        .accessibilityLabel(
                            "Stop comparison".localizedUI
                        )
                    }
                    .padding(.horizontal, PPSpacing.regular)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.62))
                            .frame(height: 0.6)
                    }
                } else if receiptPageNavigationTask != nil
                            || pendingReceiptPageOpen != nil {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Opening receipt evidence".localizedUI)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        OnDeviceBadge(compact: true)
                    }
                    .padding(.horizontal, PPSpacing.regular)
                    .frame(minHeight: 44)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.62))
                            .frame(height: 0.6)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                } else if isLoading || isRestoring {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            (
                                isRestoring
                                    ? (
                                        restoreStopRequested
                                            ? "Stopping version restore"
                                            : "Restoring version"
                                    )
                                    : "Loading versions"
                            ).localizedUI
                        )
                        .font(.caption.weight(.semibold))
                        Spacer()
                        OnDeviceBadge(compact: true)
                    }
                    .padding(.horizontal, PPSpacing.regular)
                    .frame(minHeight: 44)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.62))
                            .frame(height: 0.6)
                    }
                }
            }
            .navigationTitle("Version History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        (
                            restoreStopRequested
                                ? "Stopping"
                                : hasBlockingVersionTask
                                ? "Stop"
                                : "Close"
                        ).localizedUI
                    ) {
                        closeOrStopVersionHistory()
                    }
                    .disabled(restoreStopRequested)
                    .keyboardShortcut(.cancelAction)
                }
            }
            .task(id: versionReloadTaskID) {
                guard canReadVersionEvidence else {
                    isLoading = false
                    return
                }
                await reload()
            }
            .onChange(of: model.retainedEvidenceRevision) { _, _ in
                selectedVersion = nil
            }
            .onChange(of: currentRevisionID) {
                oldRevisionID,
                newRevisionID in
                guard oldRevisionID != nil,
                      oldRevisionID != newRevisionID
                else { return }
                invalidateRevisionEvidenceForWorkingCopyChange()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                interruptProtectedVersionWork()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                protectedDataAvailable = false
                interruptProtectedVersionWork()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.protectedDataDidBecomeAvailableNotification
                )
            ) { _ in
                protectedDataAvailable = true
            }
            .confirmationDialog(
                "Restore this version?",
                isPresented: Binding(
                    get: { selectedVersion != nil },
                    set: {
                        if !$0 {
                            selectedVersion = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let selectedVersion {
                    Button("Restore Version") {
                        restore(selectedVersion)
                    }
                }
                Button("Cancel", role: .cancel) {
                    selectedVersion = nil
                }
            } message: {
                Text(
                    "Saves the current copy first. The Files original stays unchanged."
                )
            }
            .interactiveDismissDisabled(
                hasBlockingVersionTask
            )
            .accessibilityAction(.escape) {
                closeOrStopVersionHistory()
            }
            .fullScreenCover(item: $revisionProof) { payload in
                PDFComparisonProofView(
                    configuration: PDFComparisonProofConfiguration(
                        id: [
                            "version",
                            payload.version.id.uuidString,
                            payload.revisedRevisionID.uuidString
                        ].joined(separator: ":"),
                        navigationTitle: "Historical proof",
                        evidenceLabel: "REVISION EVIDENCE",
                        sourceLabel: "SAVED",
                        sourceTitle: payload.version.displayTitle,
                        sourceURL: payload.historicalURL,
                        sourcePageCount: payload.version.pageCount,
                        sourceRefreshToken: 0,
                        sourceSymbol: "clock.arrow.circlepath",
                        revisedLabel: "CURRENT",
                        revisedTitle: payload.revisedTitle,
                        revisedURL: payload.revisedURL,
                        revisedPageCount: payload.revisedPageCount,
                        revisedRefreshToken:
                            payload.revisedRefreshToken,
                        revisedSymbol: "doc.fill",
                        recompute: { manualMatches, progress in
                            guard model.record(id: recordID)?
                                .contentRevisionID
                                == payload.revisedRevisionID
                            else {
                                throw PaperPathError
                                    .outputVerificationFailed(
                                        "the working copy changed during page-pair review"
                                    )
                            }
                            return try await model.compareVersion(
                                recordID: recordID,
                                snapshotID: payload.version.id,
                                manualMatches: manualMatches,
                                progress: progress
                            )
                        }
                    ),
                    review: payload.review
                ) { updatedReview in
                    comparisonReview = updatedReview
                }
            }
            .sheet(item: $editingMilestone) { version in
                PDFVersionMilestoneEditor(
                    recordID: recordID,
                    version: version
                ) { updated in
                    versions = updated
                    refreshPinnedStorageSummary()
                    if inspectedVersion?.id == version.id {
                        inspectedVersion = updated.first {
                            $0.id == version.id
                        }
                    }
                }
                .presentationDetents(
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? [.large]
                        : [.medium, .large]
                )
            }
            .sheet(
                item: $linkedReceiptVersion,
                onDismiss: completeReceiptPageOpen
            ) { version in
                DeliveryReceiptView(
                    recordID: recordID,
                    receiptOverride:
                        version.archivedDeliveryReceipt,
                    linkedMilestoneOverride: version,
                    onOpenRoute: { route in
                        guard let pageIndex = route.pageIndex,
                              let contentRevisionID =
                                route.expectedContentRevisionID
                        else {
                            model[noticeFor: paperPathSceneID] =
                                "The document is no longer available"
                                    .localizedUI
                            linkedReceiptVersion = nil
                            return
                        }
                        pendingReceiptPageOpen =
                            PendingReceiptPageOpen(
                                recordID: route.recordID,
                                pageIndex: pageIndex,
                                contentRevisionID:
                                    contentRevisionID
                            )
                        linkedReceiptVersion = nil
                    }
                )
            }
            .sheet(
                isPresented: $isSharingVersionArchive,
                onDismiss: cleanupVersionArchive
            ) {
                if let versionArchiveURL {
                    ShareSheet(items: [versionArchiveURL])
                }
            }
            .sheet(
                isPresented: $isSharingChangeReport,
                onDismiss: cleanupChangeReport
            ) {
                if let changeReportURL {
                    ShareSheet(items: [changeReportURL])
                }
            }
            .onDisappear {
                cancelActiveVersionWork()
                cleanupVersionArchive()
                cleanupChangeReport()
            }
            .sensoryFeedback(
                .success,
                trigger: changeReportShareCount
            )
            .sensoryFeedback(
                .error,
                trigger: loadErrorFeedback
            )
        }
    }

    private var versionReloadTaskID: VersionReloadTaskID {
        VersionReloadTaskID(
            isActive: canReadVersionEvidence,
            evidenceRevision: model.retainedEvidenceRevision,
            contentRevisionID: currentRevisionID,
            request: reloadRequest
        )
    }

    private var canReadVersionEvidence: Bool {
        scenePhase == .active
            && protectedDataAvailable
            && UIApplication.shared.isProtectedDataAvailable
    }

    private func completeReceiptPageOpen() {
        guard let request = pendingReceiptPageOpen else {
            return
        }
        pendingReceiptPageOpen = nil
        receiptPageNavigationTask?.cancel()
        let generation = UUID()
        receiptPageNavigationGeneration = generation
        receiptPageNavigationTask = Task { @MainActor in
            defer {
                if receiptPageNavigationGeneration == generation {
                    receiptPageNavigationTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  receiptPageNavigationGeneration == generation,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  let record = model.record(id: request.recordID)
            else { return }
            guard record.contentRevisionID
                    == request.contentRevisionID
            else {
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                return
            }
            onOpenPage?(request.recordID, request.pageIndex)
        }
    }

    @ViewBuilder
    private func hero(_ record: DocumentRecord) -> some View {
        WorkflowCommandHeader(
            eyebrow: "LOCAL RECOVERY",
            title: record.displayName,
            detail: "Protected versions are saved before the working copy changes.",
            symbol: "clock.arrow.circlepath",
            tint: PPColor.mint,
            metrics: [
                WorkflowMetric(
                    value: "\(versions.count)",
                    label: "Versions",
                    symbol: "clock.arrow.circlepath",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: totalVersionSize,
                    label: "Storage",
                    symbol: "internaldrive",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: String(
                        record.contentRevisionID.uuidString.prefix(8)
                    ),
                    label: "Current",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: versions.first?.createdAt.formatted(
                        date: .abbreviated,
                        time: .omitted
                    ) ?? "None",
                    label: "Latest",
                    symbol: "calendar",
                    tint: PPColor.textSecondary
                )
            ]
        )
    }

    private var historySymbol: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PPColor.surfaceMuted)
            Image(systemName: "clock.arrow.circlepath")
                .font(.title.weight(.semibold))
                .foregroundStyle(PPColor.mint)
        }
        .frame(width: 76, height: 76)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(PPColor.border.opacity(0.72), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    private func historyCopy(_ record: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            SectionEyebrow(text: "LOCAL RECOVERY")
            Text(record.displayName)
                .font(.title2.bold())
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(2)
            Label(
                AppLocalization.format(
                    versions.count == 1
                        ? "%lld protected version"
                        : "%lld protected versions",
                    versions.count
                ),
                systemImage: "lock.shield.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.mint)
        }
    }

    private func currentSummary(
        _ record: DocumentRecord
    ) -> some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(
                HStackLayout(spacing: PPSpacing.large)
            )

        return VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "CURRENT VERSION")
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Working copy".localizedUI)
                        .font(.headline)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(
                        AppLocalization.format(
                            "%lld pages · %@",
                            record.profile.pageCount,
                            record.profile.formattedSize
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                }
                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer(minLength: PPSpacing.medium)
                }
                Text(
                    String(
                        record.contentRevisionID.uuidString.prefix(8)
                    )
                )
                .font(.caption.monospaced())
                .foregroundStyle(PPColor.textSecondary)
            }
            .padding(.vertical, PPSpacing.small)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.66))
                    .frame(height: 0.6)
            }

            Group {
                if dynamicTypeSize.ppPrefersExpandedLayout {
                    VStack(spacing: 0) {
                        versionPolicyValues
                    }
                } else {
                    HStack(spacing: PPSpacing.large) {
                        versionPolicyValues
                    }
                }
            }

            if hasLoadedPinnedStorageSummary,
               pinnedStorageSummary.isNearCapacity {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        Image(
                            systemName:
                                "externaldrive.badge.exclamationmark"
                        )
                        .foregroundStyle(PPColor.amber)
                        Text(
                            "Pinned milestones are nearing the 1 GB library budget."
                                .localizedUI
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        Spacer(minLength: 0)
                        Text(
                            "\(pinnedStorageSummary.countContract) · \(pinnedStorageSummary.byteContract)"
                        )
                        .font(
                            .caption2.monospacedDigit().weight(.bold)
                        )
                        .foregroundStyle(PPColor.amber)
                    }

                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xSmall
                    ) {
                        Label(
                            "Pinned milestones are nearing the 1 GB library budget."
                                .localizedUI,
                            systemImage:
                                "externaldrive.badge.exclamationmark"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        Text(
                            "\(pinnedStorageSummary.countContract) · \(pinnedStorageSummary.byteContract)"
                        )
                        .font(
                            .caption2.monospacedDigit().weight(.bold)
                        )
                        .foregroundStyle(PPColor.amber)
                    }
                }
                .padding(.vertical, PPSpacing.small)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(PPColor.amber)
                        .frame(width: 2)
                }
            }

            if pinnedVersionCount > 0 {
                Button {
                    if isCreatingVersionArchive {
                        stopVersionArchiveCreation()
                    } else {
                        createVersionArchive()
                    }
                } label: {
                    Label(
                        isCreatingVersionArchive
                            ? "Stop archiving"
                            : "Export Milestone Archive",
                        systemImage: isCreatingVersionArchive
                            ? "xmark.circle.fill"
                            : "archivebox"
                    )
                }
                .buttonStyle(
                    PPQuietButtonStyle(
                        tint: isCreatingVersionArchive
                            ? PPColor.amber
                            : PPColor.cyan
                    )
                )
                .disabled(
                    !isCreatingVersionArchive
                        && hasNonArchiveVersionTask
                )
                .accessibilityHint(
                    (
                        isCreatingVersionArchive
                            ? "Stops archive creation."
                            : versionActionDisabledReason
                                ?? "Creates a local archive of pinned milestones."
                    ).localizedUI
                )
            }
        }
    }

    private var currentRevisionID: UUID? {
        model.record(id: recordID)?.contentRevisionID
    }

    private func revisionBench(
        _ version: PDFVersionSnapshot,
        current: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            StudioSectionRule(
                title: "REVISION BENCH",
                detail: version.createdAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                ),
                symbol: "rectangle.split.2x1",
                count: comparisonReview?.changes.count,
                tint: PPColor.amber
            )

            ViewThatFits(in: .horizontal) {
                HStack(
                    alignment: .top,
                    spacing: PPSpacing.large
                ) {
                    revisionPreview(
                        label: "SAVED",
                        title: AppLocalization.format(
                            "%@",
                            version.displayTitle
                        ),
                        url: inspectedVersionURL,
                        pageCount: version.pageCount,
                        size: version.formattedSize,
                        tint: PPColor.cyan
                    )
                    revisionArrow
                    revisionPreview(
                        label: "CURRENT",
                        title: "Working copy",
                        url: model.url(for: recordID),
                        pageCount: current.profile.pageCount,
                        size: current.profile.formattedSize,
                        tint: PPColor.amber
                    )
                }
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.medium
                ) {
                    revisionPreview(
                        label: "SAVED",
                        title: AppLocalization.format(
                            "Before %@",
                            version.label.localizedUI
                        ),
                        url: inspectedVersionURL,
                        pageCount: version.pageCount,
                        size: version.formattedSize,
                        tint: PPColor.cyan
                    )
                    revisionPreview(
                        label: "CURRENT",
                        title: "Working copy",
                        url: model.url(for: recordID),
                        pageCount: current.profile.pageCount,
                        size: current.profile.formattedSize,
                        tint: PPColor.amber
                    )
                }
            }

            if let review = comparisonReview {
                HStack(spacing: PPSpacing.large) {
                    revisionMetric(
                        value: "\(review.criticalChanges.count)",
                        label: "Critical",
                        tint: PPColor.rose
                    )
                    revisionMetric(
                        value: "\(review.insertedPages.count)",
                        label: "Inserted",
                        tint: PPColor.cyan
                    )
                    revisionMetric(
                        value: "\(review.removedPages.count)",
                        label: "Removed",
                        tint: PPColor.amber
                    )
                    revisionMetric(
                        value: "\(review.textChangedPageCount)",
                        label: "Text",
                        tint: PPColor.accent
                    )
                }

                ForEach(review.changes.prefix(4)) { change in
                    HStack(spacing: PPSpacing.small) {
                        Image(
                            systemName: change.resolvedMatchKind
                                == .inserted
                                ? "plus.circle"
                                : change.resolvedMatchKind == .removed
                                    ? "minus.circle"
                                    : "pencil.line"
                        )
                        .foregroundStyle(
                            change.severity == .critical
                                ? PPColor.rose
                                : PPColor.amber
                        )
                        Text(revisionPageLabel(change))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Text(change.resolvedMatchKind.title.localizedUI)
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                        Spacer(minLength: 0)
                        Text(change.severity.title.localizedUI)
                            .font(.caption2.smallCaps().weight(.bold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    .frame(minHeight: 28)
                }
            } else if isComparing {
                LocalComparisonProgressView(
                    progress: comparisonProgress,
                    compact: true
                )
            } else if let comparisonError {
                Label(
                    comparisonError.localizedUI,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
                .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.medium) {
                    revisionActionButtons(version)
                }
                VStack(spacing: PPSpacing.small) {
                    revisionActionButtons(version)
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    @ViewBuilder
    private func revisionActionButtons(
        _ version: PDFVersionSnapshot
    ) -> some View {
        if let inspectedVersionURL,
           let comparisonReview,
           let currentRecord = model.record(id: recordID),
           let currentURL = model.url(for: recordID) {
            Button {
                revisionProof = RevisionProofPayload(
                    version: version,
                    historicalURL: inspectedVersionURL,
                    revisedRevisionID:
                        currentRecord.contentRevisionID,
                    revisedTitle: currentRecord.displayName,
                    revisedURL: currentURL,
                    revisedPageCount:
                        currentRecord.profile.pageCount,
                    revisedRefreshToken:
                        model.refreshToken(for: recordID),
                    review: comparisonReview
                )
            } label: {
                Label(
                    "Open Full Proof",
                    systemImage: "rectangle.split.2x1"
                )
            }
            .buttonStyle(
                PPQuietButtonStyle(tint: PPColor.amber)
            )
            .disabled(
                hasBlockingVersionTask
            )
            .accessibilityHint(
                versionActionHint(
                    "Opens the full page comparison proof."
                )
            )

            Button {
                prepareChangeReport(
                    version: version,
                    review: comparisonReview
                )
            } label: {
                Label(
                    changeReportTask == nil
                        ? "Export Signed Change Report"
                        : "Preparing change report",
                    systemImage: changeReportTask == nil
                        ? "doc.text"
                        : "hourglass"
                )
            }
            .buttonStyle(
                PPQuietButtonStyle(tint: PPColor.cyan)
            )
            .disabled(
                hasBlockingVersionTask
            )
            .accessibilityHint(
                versionActionHint(
                    "Includes limited text evidence and a signature, but no PDFs."
                )
            )
        }

        Button {
            inspect(version)
        } label: {
            Label(
                "Compare Again",
                systemImage: "arrow.clockwise"
            )
        }
        .buttonStyle(
            PPQuietButtonStyle(tint: PPColor.cyan)
        )
        .disabled(
            hasBlockingVersionTask
        )
        .accessibilityHint(
            versionActionHint(
                "Recalculates differences against the working copy."
            )
        )

        Button {
            editingMilestone = version
        } label: {
            Label(
                version.isPinnedMilestone
                    ? "Edit Milestone"
                    : "Save as Milestone",
                systemImage: version.isPinnedMilestone
                    ? "pin.fill"
                    : "pin"
            )
        }
        .buttonStyle(
            PPQuietButtonStyle(tint: PPColor.mint)
        )
        .disabled(
            hasBlockingVersionTask
        )
        .accessibilityHint(
            versionActionHint(
                "Opens milestone name, protection, and receipt settings."
            )
        )
        .accessibilityIdentifier(
            "editInspectedVersionMilestone-\(version.id.uuidString)"
        )

        Button {
            selectedVersion = version
        } label: {
            Label(
                "Restore This Revision",
                systemImage: "arrow.uturn.backward"
            )
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            hasBlockingVersionTask
        )
        .accessibilityHint(
            versionActionHint(
                "Saves the current copy first, then restores this version."
            )
        )
    }

    private func revisionPreview(
        label: String,
        title: String,
        url: URL?,
        pageCount: Int,
        size: String,
        tint: Color
    ) -> some View {
        HStack(spacing: PPSpacing.medium) {
            if let url {
                PDFPageThumbnailView(
                    url: url,
                    pageIndex: 0,
                    refreshToken: label == "CURRENT"
                        ? model.refreshToken(for: recordID)
                        : 0,
                    width: 66
                )
                .shadow(
                    color: .black.opacity(0.1),
                    radius: 4,
                    y: 2
                )
            } else {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: 5,
                        style: .continuous
                    )
                    .fill(PPColor.elevated)
                    Image(systemName: "doc.questionmark")
                        .font(.title3)
                        .foregroundStyle(PPColor.textSecondary)
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 5,
                        style: .continuous
                    )
                    .stroke(
                        PPColor.border.opacity(0.64),
                        lineWidth: 0.55
                    )
                }
                    .frame(width: 66, height: 84)
                .accessibilityLabel("Revision preview unavailable")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label.localizedUI)
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(tint)
                Text(title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(2)
                Text(
                    AppLocalization.format(
                        "%lld pages · %@",
                        pageCount,
                        size
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var revisionArrow: some View {
        Image(systemName: "arrow.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(PPColor.textSecondary)
            .padding(.top, 34)
            .accessibilityHidden(true)
    }

    private func revisionMetric(
        value: String,
        label: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func history(_ record: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "SAVED BEFORE EDITS")

            if let loadErrorMessage {
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    Label(
                        loadErrorMessage.localizedUI,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .fixedSize(horizontal: false, vertical: true)

                    Button {
                        reloadRequest &+= 1
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.cyan)
                    )
                    .disabled(isLoading)
                    .accessibilityIdentifier("retryVersionHistory")
                }
                .padding(.vertical, PPSpacing.small)
            }

            if versions.isEmpty
                && !isLoading
                && loadErrorMessage == nil {
                ContentUnavailableView(
                    "No recovery versions yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "A protected version appears here before the working copy changes."
                    )
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, PPSpacing.section)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(versions.enumerated()), id: \.element.id) {
                        index,
                        version in
                        versionRow(
                            version,
                            current: record,
                            isLast: index == versions.count - 1
                        )
                    }
                }
            }
        }
    }

    private func versionRow(
        _ version: PDFVersionSnapshot,
        current: DocumentRecord,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            VStack(spacing: 0) {
                Circle()
                    .fill(
                        isCurrent(version, record: current)
                            ? PPColor.mint
                            : PPColor.accent
                    )
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle()
                            .stroke(PPColor.canvas, lineWidth: 2)
                    }
                if !isLast {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.78))
                        .frame(width: 1)
                        .frame(minHeight: 86)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 5) {
                Text(version.displayTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? nil
                        : 2
                )

                if isCurrent(version, record: current),
                   dynamicTypeSize.ppPrefersExpandedLayout {
                    Label(
                        "CURRENT COPY".localizedUI,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.mint)
                }

                Text(
                    version.createdAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)

                Text(comparisonContext(version, current: current))
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? 3
                            : 2
                    )

                Text(shortFingerprint(version.contentFingerprint))
                    .font(.caption2.monospaced())
                    .foregroundStyle(PPColor.textSecondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        versionBadges(version)
                    }
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xSmall
                    ) {
                        versionBadges(version)
                    }
                }
                .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCurrent(version, record: current) {
                VStack(alignment: .trailing, spacing: 2) {
                    if !dynamicTypeSize.ppPrefersExpandedLayout {
                        Text("CURRENT COPY".localizedUI)
                            .font(
                                .caption2.smallCaps().weight(.bold)
                            )
                            .foregroundStyle(PPColor.mint)
                    }
                    Button {
                        editingMilestone = version
                    } label: {
                        Image(
                            systemName: version.isPinnedMilestone
                                ? "pin.fill"
                                : "pin"
                        )
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        version.isPinnedMilestone
                            ? PPColor.mint
                            : PPColor.textSecondary
                    )
                    .accessibilityLabel(
                        (
                            version.isPinnedMilestone
                                ? "Edit milestone"
                                : "Save as milestone"
                        ).localizedUI
                    )
                    .disabled(hasBlockingVersionTask)
                    .accessibilityHint(
                        (versionActionDisabledReason ?? "")
                            .localizedUI
                    )
                }
                .padding(.top, 2)
            } else {
                versionRowActions(version)
            }
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func versionBadges(
        _ version: PDFVersionSnapshot
    ) -> some View {
        if version.isPinnedMilestone {
            Label(
                "Pinned milestone",
                systemImage: "pin.fill"
            )
            .foregroundStyle(PPColor.mint)
        }
        if version.linkedDeliveryReceiptID != nil {
            linkedReceiptControl(version)
        }
    }

    @ViewBuilder
    private func versionRowActions(
        _ version: PDFVersionSnapshot
    ) -> some View {
        if horizontalSizeClass == .compact
            || dynamicTypeSize.ppPrefersExpandedLayout {
            Menu {
                Button {
                    editingMilestone = version
                } label: {
                    Label(
                        (
                            version.isPinnedMilestone
                                ? "Edit milestone"
                                : "Save as milestone"
                        ).localizedUI,
                        systemImage: version.isPinnedMilestone
                            ? "pin.fill"
                            : "pin"
                    )
                }
                Button {
                    inspect(version)
                } label: {
                    Label(
                        "Compare with working copy".localizedUI,
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                Button {
                    selectedVersion = version
                } label: {
                    Label(
                        "Restore version".localizedUI,
                        systemImage: "arrow.uturn.backward.circle"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.accent)
            .disabled(hasBlockingVersionTask)
            .accessibilityLabel("Version actions".localizedUI)
            .accessibilityHint(
                (versionActionDisabledReason ?? "")
                    .localizedUI
            )
        } else {
            Button {
                editingMilestone = version
            } label: {
                Image(
                    systemName: version.isPinnedMilestone
                        ? "pin.fill"
                        : "pin"
                )
                .font(.body)
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                version.isPinnedMilestone
                    ? PPColor.mint
                    : PPColor.textSecondary
            )
            .disabled(hasBlockingVersionTask)
            .accessibilityLabel(
                (
                    version.isPinnedMilestone
                        ? "Edit milestone"
                        : "Save as milestone"
                ).localizedUI
            )
            .accessibilityHint(
                versionActionHint(
                    "Opens milestone name, protection, and receipt settings."
                )
            )

            Button {
                inspect(version)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.body)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.cyan)
            .disabled(hasBlockingVersionTask)
            .accessibilityLabel(
                "Compare this version with the working copy"
                    .localizedUI
            )
            .accessibilityHint(
                versionActionHint(
                    "Calculates page and text differences."
                )
            )

            Button {
                selectedVersion = version
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.accent)
            .disabled(hasBlockingVersionTask)
            .accessibilityLabel(
                AppLocalization.format(
                    "Restore version from %@",
                    version.createdAt.formatted()
                )
            )
            .help("Restore this version")
            .accessibilityHint(
                versionActionHint(
                    "Saves the current copy first, then restores this version."
                )
            )
        }
    }

    @ViewBuilder
    private func linkedReceiptControl(
        _ version: PDFVersionSnapshot
    ) -> some View {
        if let receipt = version.archivedDeliveryReceipt {
            Button {
                linkedReceiptVersion = version
            } label: {
                Label(
                    "Open archived receipt",
                    systemImage: "checkmark.seal.fill"
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.cyan)
            .disabled(hasBlockingVersionTask)
            .accessibilityIdentifier(
                "openMilestoneReceipt-\(version.id.uuidString)"
            )
            .accessibilityHint(
                versionActionDisabledReason?.localizedUI
                    ?? AppLocalization.format(
                        "Opens the receipt issued %@",
                        receipt.createdAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
            )
        } else if let receipt =
                    model.record(id: recordID)?.deliveryReceipt,
                  version.linkedDeliveryReceiptID == receipt.id {
            if version.matchesDeliveryReceipt(receipt) {
                Button {
                    linkedReceiptVersion = version
                } label: {
                    Label(
                        "Open linked receipt",
                        systemImage: "checkmark.seal.fill"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.cyan)
                .disabled(hasBlockingVersionTask)
                .accessibilityIdentifier(
                    "openMilestoneReceipt-\(version.id.uuidString)"
                )
                .accessibilityHint(
                    (versionActionDisabledReason ?? "")
                        .localizedUI
                )
            } else {
                Label(
                    "Receipt link mismatch",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(PPColor.amber)
                .accessibilityHint(
                    "The stored revision or fingerprint does not match this version."
                        .localizedUI
                )
            }
        } else {
            Label(
                "Linked receipt unavailable",
                systemImage: "checkmark.seal"
            )
            .foregroundStyle(PPColor.textSecondary)
            .accessibilityHint(
                "The original receipt is no longer stored with this working copy."
                    .localizedUI
            )
        }
    }

    private func policyValue(
        value: String,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var versionPolicyValues: some View {
        policyValue(
            value: "12",
            label: "Rotating"
        )
        policyValue(
            value: "\(pinnedVersionCount)",
            label: "Milestones"
        )
        policyValue(
            value: hasLoadedPinnedStorageSummary
                ? pinnedStorageSummary.formattedBytes
                : "Unavailable".localizedUI,
            label: "Pinned storage"
        )
    }

    private var totalVersionSize: String {
        PDFPinnedVersionStorageSummary
            .measuring(versions)
            .formattedBytes
    }

    private var pinnedVersionCount: Int {
        versions.filter(\.isPinnedMilestone).count
    }

    private var hasNonArchiveVersionTask: Bool {
        isRestoring
            || changeReportTask != nil
            || isComparing
    }

    private var hasBlockingVersionTask: Bool {
        hasNonArchiveVersionTask
            || isCreatingVersionArchive
            || receiptPageNavigationTask != nil
            || pendingReceiptPageOpen != nil
    }

    private var versionActionDisabledReason: String? {
        if isRestoring {
            return "Wait for version restore to finish."
        }
        if isCreatingVersionArchive {
            return "Wait for milestone archive creation to finish."
        }
        if changeReportTask != nil {
            return "Wait for the change report to finish."
        }
        if isComparing {
            return "Wait for the current comparison to finish."
        }
        if receiptPageNavigationTask != nil
            || pendingReceiptPageOpen != nil {
            return "Wait for the selected receipt page to open."
        }
        return nil
    }

    private func closeOrStopVersionHistory() {
        if isRestoring {
            stopRestore()
        } else if isCreatingVersionArchive {
            stopVersionArchiveCreation()
        } else if changeReportTask != nil {
            stopChangeReportCreation()
        } else if isComparing {
            stopComparison()
        } else if receiptPageNavigationTask != nil
                    || pendingReceiptPageOpen != nil {
            stopReceiptPageNavigation()
        } else {
            dismiss()
        }
    }

    private func versionActionHint(
        _ availableHint: String
    ) -> String {
        (
            versionActionDisabledReason
                ?? availableHint
        ).localizedUI
    }

    private func isCurrent(
        _ version: PDFVersionSnapshot,
        record: DocumentRecord
    ) -> Bool {
        version.contentFingerprint == record.contentFingerprint
    }

    private func comparisonContext(
        _ version: PDFVersionSnapshot,
        current: DocumentRecord
    ) -> String {
        var parts = [
            AppLocalization.format(
                "%lld pages",
                version.pageCount
            ),
            version.formattedSize
        ]
        let pageDelta = version.pageCount - current.profile.pageCount
        if pageDelta != 0 {
            parts.append(
                pageDelta > 0
                    ? AppLocalization.format(
                        "%lld more pages",
                        pageDelta
                    )
                    : AppLocalization.format(
                        "%lld fewer pages",
                        -pageDelta
                    )
            )
        } else {
            parts.append("Same page count".localizedUI)
        }
        let byteDelta = version.byteCount - current.profile.byteCount
        if abs(byteDelta) >= 1_024 {
            parts.append(
                AppLocalization.format(
                    byteDelta > 0 ? "%@ larger" : "%@ smaller",
                    ByteCountFormatter.string(
                        fromByteCount: abs(byteDelta),
                        countStyle: .file
                    )
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    private func shortFingerprint(_ value: String) -> String {
        String(value.prefix(12)).enumerated().reduce(into: "") {
            result,
            pair in
            if pair.offset > 0, pair.offset.isMultiple(of: 4) {
                result.append(" ")
            }
            result.append(pair.element)
        }
    }

    private func revisionPageLabel(
        _ change: PDFPageChange
    ) -> String {
        let source = change.resolvedSourcePageIndex.map {
            "S\($0 + 1)"
        } ?? "S—"
        let revised = change.resolvedRevisedPageIndex.map {
            "C\($0 + 1)"
        } ?? "C—"
        return "\(source) → \(revised)"
    }

    private func reload() async {
        guard canReadVersionEvidence, !Task.isCancelled else { return }
        let request = versionReloadTaskID
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }
        let overview = await model.versionHistoryOverview(
            recordID: recordID
        )
        guard !Task.isCancelled,
              canReadVersionEvidence,
              request == versionReloadTaskID,
              generation == loadGeneration
        else { return }
        guard let overview else {
            loadErrorMessage =
                "Version history could not be loaded. Try again."
            hasLoadedPinnedStorageSummary = false
            loadErrorFeedback += 1
            return
        }
        loadErrorMessage = nil
        versions = overview.versions
        pinnedStorageSummary = overview.pinnedStorageSummary
        hasLoadedPinnedStorageSummary = true
        if let inspectedVersion {
            if let updated = overview.versions.first(where: { $0.id == inspectedVersion.id }),
               updated.contentFingerprint == inspectedVersion.contentFingerprint,
               updated.contentRevisionID == inspectedVersion.contentRevisionID {
                self.inspectedVersion = updated
            } else {
                stopComparison()
                self.inspectedVersion = nil
                inspectedVersionURL = nil
                comparisonReview = nil
                revisionProof = nil
            }
        }
        if !appliedInitialVersion {
            appliedInitialVersion = true
            if let initialVersionID,
               let initial = overview.versions.first(where: {
                   $0.id == initialVersionID
               }) {
                inspect(initial)
            }
        }
    }

    private func refreshPinnedStorageSummary() {
        pinnedStorageTask?.cancel()
        let generation = UUID()
        pinnedStorageGeneration = generation
        pinnedStorageTask = Task { @MainActor in
            defer {
                if pinnedStorageGeneration == generation {
                    pinnedStorageTask = nil
                }
            }
            let summary = await model.pinnedVersionStorageSummary()
            guard !Task.isCancelled,
                  pinnedStorageGeneration == generation
            else { return }
            guard let summary else {
                hasLoadedPinnedStorageSummary = false
                return
            }
            pinnedStorageSummary = summary
            hasLoadedPinnedStorageSummary = true
        }
    }

    private func cancelActiveVersionWork() {
        loadGeneration &+= 1
        isLoading = false
        stopReceiptPageNavigation()
        versionArchiveGeneration = UUID()
        versionArchiveTask?.cancel()
        versionArchiveTask = nil
        versionArchiveProgress = nil
        versionArchiveRateWindow.reset()
        isCreatingVersionArchive = false
        stopRestore(invalidateResult: true)
        comparisonGeneration &+= 1
        comparisonTask?.cancel()
        comparisonTask = nil
        isComparing = false
        comparisonProgress = .starting
        changeReportGeneration = UUID()
        changeReportTask?.cancel()
        changeReportTask = nil
        pinnedStorageGeneration = UUID()
        pinnedStorageTask?.cancel()
        pinnedStorageTask = nil
    }

    private func stopReceiptPageNavigation() {
        receiptPageNavigationGeneration = UUID()
        receiptPageNavigationTask?.cancel()
        receiptPageNavigationTask = nil
        pendingReceiptPageOpen = nil
    }

    private func interruptProtectedVersionWork() {
        let wasComparing = isComparing
        cancelActiveVersionWork()
        selectedVersion = nil
        editingMilestone = nil
        linkedReceiptVersion = nil
        revisionProof = nil
        comparisonReview = nil
        inspectedVersionURL = nil
        inspectedVersion = nil
        versions = []
        hasLoadedPinnedStorageSummary = false
        appliedInitialVersion = false
        isSharingVersionArchive = false
        isSharingChangeReport = false
        cleanupVersionArchive()
        cleanupChangeReport()
        guard wasComparing else { return }
        comparisonError =
            "Comparison stopped. Start again when PaperPath is active."
    }

    private func invalidateRevisionEvidenceForWorkingCopyChange() {
        let hadEvidence = comparisonReview != nil
            || revisionProof != nil
            || isComparing
            || changeReportTask != nil
        stopComparison()
        revisionProof = nil
        comparisonReview = nil
        changeReportGeneration = UUID()
        changeReportTask?.cancel()
        changeReportTask = nil
        isSharingChangeReport = false
        cleanupChangeReport()
        guard hadEvidence else { return }
        comparisonError =
            "The working copy changed. Compare it with the saved version again."
    }

    private func createVersionArchive() {
        guard versionArchiveTask == nil,
              !hasNonArchiveVersionTask
        else { return }
        cleanupVersionArchive()
        let generation = UUID()
        versionArchiveGeneration = generation
        versionArchiveRateWindow.reset()
        versionArchiveProgress = PDFOperationProgress(
            label: "Archiving milestones",
            fractionCompleted: 0,
            byteStage: .checksumming
        )
        isCreatingVersionArchive = true
        versionArchiveTask = Task { @MainActor in
            let archive = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.makePinnedVersionArchive(
                    recordID: recordID
                ) { update in
                    guard versionArchiveGeneration == generation else {
                        return
                    }
                    if let progress = versionArchiveRateWindow
                        .operationProgress(
                            label: "Archiving milestones",
                            update: update,
                            current: versionArchiveProgress
                        ) {
                        versionArchiveProgress = progress
                    }
                }
            }
            guard versionArchiveGeneration == generation else {
                if let archive {
                    await model.discardVersionArchive(at: archive)
                }
                return
            }
            versionArchiveGeneration = UUID()
            isCreatingVersionArchive = false
            versionArchiveTask = nil
            versionArchiveProgress = nil
            versionArchiveRateWindow.reset()
            guard !Task.isCancelled else {
                if let archive {
                    await model.discardVersionArchive(at: archive)
                }
                return
            }
            guard let archive else { return }
            versionArchiveURL = archive
            isSharingVersionArchive = true
        }
    }

    private func stopVersionArchiveCreation() {
        versionArchiveGeneration = UUID()
        versionArchiveTask?.cancel()
        versionArchiveTask = nil
        versionArchiveProgress = nil
        versionArchiveRateWindow.reset()
        isCreatingVersionArchive = false
    }

    private func cleanupVersionArchive() {
        guard let archive = versionArchiveURL else { return }
        versionArchiveURL = nil
        Task {
            await model.discardVersionArchive(at: archive)
        }
    }

    private func prepareChangeReport(
        version: PDFVersionSnapshot,
        review: PDFChangeReview
    ) {
        guard changeReportTask == nil,
              !isRestoring,
              !isCreatingVersionArchive,
              !isComparing,
              let current = model.record(id: recordID)
        else { return }
        cleanupChangeReport()
        let generation = UUID()
        changeReportGeneration = generation
        let descriptor = PDFChangeReportDescriptor(
            reportID: UUID(),
            scope: "Saved version comparison".localizedUI,
            sourceName: version.displayTitle,
            revisedName: current.displayName,
            sourceRevisionID: version.contentRevisionID,
            revisedRevisionID: current.contentRevisionID,
            sourceFingerprint: version.contentFingerprint,
            revisedFingerprint: current.contentFingerprint,
            deliveryReceiptID: version.linkedDeliveryReceiptID,
            generatedAt: PDFOfficeTimeAnchor.process.trustedDate()
        )
        changeReportTask = Task { @MainActor in
            let url = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.makeChangeReport(
                    review: review,
                    descriptor: descriptor,
                    validatingRevisions: [
                        current.id: current.contentRevisionID
                    ],
                    localLink: PDFRetainedChangeReportLocalLink
                        .versionSnapshot(
                            version,
                            current: current
                        )
                )
            }
            guard changeReportGeneration == generation else {
                if let url {
                    await model.discardChangeReport(at: url)
                }
                return
            }
            changeReportTask = nil
            guard !Task.isCancelled else {
                if let url {
                    await model.discardChangeReport(at: url)
                }
                return
            }
            guard let url else { return }
            changeReportURL = url
            changeReportShareCount += 1
            isSharingChangeReport = true
        }
    }

    private func cleanupChangeReport() {
        guard let url = changeReportURL else { return }
        changeReportURL = nil
        Task {
            await model.discardChangeReport(at: url)
        }
    }

    private func stopChangeReportCreation() {
        changeReportGeneration = UUID()
        changeReportTask?.cancel()
        changeReportTask = nil
    }

    private func inspect(_ version: PDFVersionSnapshot) {
        guard scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable,
              !isRestoring,
              !isCreatingVersionArchive,
              changeReportTask == nil
        else {
            comparisonError =
                "Comparison stopped. Start again when PaperPath is active."
            return
        }
        comparisonGeneration &+= 1
        let generation = comparisonGeneration
        comparisonTask?.cancel()
        inspectedVersion = version
        inspectedVersionURL = nil
        comparisonReview = nil
        comparisonError = nil
        isComparing = true
        comparisonProgress = .starting
        comparisonTask = Task {
            defer {
                if comparisonGeneration == generation {
                    isComparing = false
                    comparisonTask = nil
                    comparisonProgress = .starting
                }
            }
            async let loadedURL = model.versionFileURL(
                recordID: recordID,
                snapshotID: version.id
            )
            do {
                let review = try await model.withFeedbackTarget(
                    paperPathSceneID
                ) {
                    try await model.compareVersion(
                        recordID: recordID,
                        snapshotID: version.id
                    ) { update in
                        guard comparisonGeneration == generation,
                              inspectedVersion?.id == version.id,
                              update.fractionCompleted
                                >= comparisonProgress
                                    .fractionCompleted
                        else { return }
                        comparisonProgress = update
                    }
                }
                let url = await loadedURL
                guard !Task.isCancelled,
                      comparisonGeneration == generation,
                      inspectedVersion?.id == version.id
                else { return }
                guard let url else {
                    comparisonError =
                        "The selected version could not be reopened."
                    return
                }
                inspectedVersionURL = url
                comparisonReview = review
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      comparisonGeneration == generation
                else { return }
                comparisonError = AppLocalization
                    .userFacingErrorDescription(error)
                model.present(error, in: paperPathSceneID)
            }
        }
    }

    private func stopComparison() {
        comparisonGeneration &+= 1
        comparisonTask?.cancel()
        comparisonTask = nil
        isComparing = false
        comparisonProgress = .starting
        comparisonError = nil
    }

    private func restore(_ version: PDFVersionSnapshot) {
        guard restoreTask == nil,
              !isCreatingVersionArchive,
              !isComparing,
              changeReportTask == nil,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        selectedVersion = nil
        let generation = UUID()
        restoreGeneration = generation
        restoreStopRequested = false
        isRestoring = true
        restoreTask = Task { @MainActor in
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.restoreVersion(
                    recordID: recordID,
                    snapshotID: version.id
                )
            }
            guard restoreGeneration == generation else { return }
            let wasStopped =
                restoreStopRequested || Task.isCancelled
            isRestoring = false
            restoreTask = nil
            restoreStopRequested = false
            if wasStopped {
                if succeeded {
                    model[noticeFor: paperPathSceneID] =
                        "Version restore finished before stopping · restored version kept"
                            .localizedUI
                    reloadRequest &+= 1
                } else {
                    model[noticeFor: paperPathSceneID] =
                        "Version restore stopped · working copy unchanged"
                            .localizedUI
                }
            } else if succeeded {
                dismiss()
            } else {
                await reload()
            }
        }
    }

    private func stopRestore(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            restoreGeneration = UUID()
            restoreStopRequested = false
        } else {
            guard restoreTask != nil,
                  !restoreStopRequested
            else { return }
            restoreStopRequested = true
        }
        restoreTask?.cancel()
        if invalidateResult {
            restoreTask = nil
            isRestoring = false
        }
    }
}

private struct PDFVersionMilestoneEditor: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @FocusState private var isNameFieldFocused: Bool

    let recordID: UUID
    let version: PDFVersionSnapshot
    let onSave: ([PDFVersionSnapshot]) -> Void

    @State private var name: String
    @State private var isPinned: Bool
    @State private var linksDelivery: Bool
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?
    @State private var saveGeneration = UUID()
    @State private var saveStopRequested = false
    @State private var pinnedStorageSummary =
        PDFPinnedVersionStorageSummary.empty
    @State private var hasLoadedPinnedStorageSummary = false
    @State private var capacityErrorMessage: String?
    @State private var capacityErrorFeedback = 0
    @State private var capacityReloadRequest = 0
    @State private var saveErrorMessage: String?
    @State private var saveErrorFeedback = 0
    @State private var isConfirmingDiscard = false

    init(
        recordID: UUID,
        version: PDFVersionSnapshot,
        onSave: @escaping ([PDFVersionSnapshot]) -> Void
    ) {
        self.recordID = recordID
        self.version = version
        self.onSave = onSave
        _name = State(initialValue: version.resolvedMilestoneName ?? "")
        _isPinned = State(
            initialValue: version.isPinnedMilestone
        )
        _linksDelivery = State(
            initialValue: version.linkedDeliveryReceiptID != nil
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PPSpacing.large) {
                    WorkflowCommandHeader(
                        eyebrow: "VERSION MILESTONE",
                        title: version.displayTitle,
                        detail:
                            "Pinned milestones stay outside automatic version rotation.",
                        symbol: "pin.fill",
                        tint: PPColor.mint,
                        metrics: [
                            WorkflowMetric(
                                value: "\(version.pageCount)",
                                label: "Pages",
                                symbol: "doc.on.doc",
                                tint: PPColor.accent
                            ),
                            WorkflowMetric(
                                value: version.formattedSize,
                                label: "Storage",
                                symbol: "internaldrive",
                                tint: PPColor.cyan
                            ),
                            WorkflowMetric(
                                value: version.createdAt.formatted(
                                    date: .abbreviated,
                                    time: .omitted
                                ),
                                label: "Created",
                                symbol: "calendar",
                                tint: PPColor.amber
                            )
                        ]
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        SectionEyebrow(text: "MILESTONE NAME")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: PPSpacing.xSmall) {
                                milestoneNameField
                                milestoneNamePasteButton
                            }
                            VStack(
                                alignment: .trailing,
                                spacing: PPSpacing.xSmall
                            ) {
                                milestoneNameField
                                milestoneNamePasteButton
                            }
                        }
                    }

                    Toggle(isOn: $isPinned) {
                        Label(
                            "Protect from automatic cleanup",
                            systemImage: "pin"
                        )
                    }
                    .tint(PPColor.mint)
                    .onChange(of: isPinned) { _, pinned in
                        saveErrorMessage = nil
                        if !pinned {
                            linksDelivery = false
                        }
                    }

                    Toggle(isOn: $linksDelivery) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(
                                receiptLinkTitle,
                                systemImage: "checkmark.seal"
                            )
                            Text(receiptLinkDetail)
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                    }
                    .tint(PPColor.cyan)
                    .disabled(!canManageReceiptLink)
                    .accessibilityIdentifier("milestoneReceiptLink")
                    .onChange(of: linksDelivery) { _, linked in
                        saveErrorMessage = nil
                        if linked {
                            isPinned = true
                        }
                    }

                    if let saveErrorMessage {
                        Label(
                            saveErrorMessage.localizedUI,
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.rose)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "milestoneSaveError"
                        )
                    }

                    milestoneCapacityStatus
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PPSpacing.regular)
                .disabled(isSaving)
            }
            .accessibilityIdentifier("versionMilestoneEditor")
            .background(PPColor.canvas)
            .navigationTitle("Version milestone".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            saveStopRequested
                                ? "Stopping"
                                : isSaving
                                    ? "Stop"
                                    : "Cancel"
                        ).localizedUI
                    ) {
                        if isSaving {
                            stopSaving()
                        } else {
                            requestDismissal()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saveStopRequested)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 44, height: 44)
                                .accessibilityLabel(
                                    (
                                        saveStopRequested
                                            ? "Finishing milestone update"
                                            : "Saving milestone"
                                    ).localizedUI
                                )
                        } else {
                            Text("Save".localizedUI)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(
                        isSaving
                            || cannotSaveMilestone
                            || !hasMilestoneChanges
                    )
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(
                        (
                            milestoneSaveDisabledReason
                                ?? "Saves this version milestone."
                        ).localizedUI
                    )
                }
            }
        }
        .task(id: capacityReloadRequest) {
            await loadPinnedStorageSummary()
        }
        .confirmationDialog(
            "Discard milestone changes?".localizedUI,
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(
                "Discard Milestone Changes".localizedUI,
                role: .destructive
            ) {
                dismiss()
            }
            Button("Keep Editing".localizedUI, role: .cancel) {}
        } message: {
            Text(
                "Milestone changes have not been saved.".localizedUI
            )
        }
        .interactiveDismissDisabled(isSaving || hasMilestoneChanges)
        .accessibilityAction(.escape) {
            if isSaving {
                stopSaving()
            } else {
                requestDismissal()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptProtectedMilestoneEditing()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtectedMilestoneEditing()
        }
        .onDisappear {
            invalidateMilestoneSave()
            name = ""
        }
        .sensoryFeedback(
            .error,
            trigger: capacityErrorFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: saveErrorFeedback
        )
    }

    private var milestoneNameField: some View {
        TextField(
            "e.g. Signed contract",
            text: $name
        )
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.words)
        .submitLabel(.done)
        .focused($isNameFieldFocused)
        .onSubmit {
            isNameFieldFocused = false
        }
        .onChange(of: name) { _, value in
            saveErrorMessage = nil
            if value.count > 80 {
                name = String(value.prefix(80))
            }
        }
    }

    private var milestoneNamePasteButton: some View {
        PasteButton(payloadType: String.self) { values in
            guard let value = values.first else { return }
            name = String(
                value
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .prefix(80)
            )
            isNameFieldFocused = false
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(isSaving)
        .accessibilityLabel("Paste milestone name".localizedUI)
        .accessibilityHint(
            "Pastes a local name for this protected version."
                .localizedUI
        )
    }

    private var storedReceipt: PDFDeliveryReceipt? {
        model.record(id: recordID)?.deliveryReceipt
    }

    private var matchesStoredReceipt: Bool {
        storedReceipt.map(version.matchesDeliveryReceipt) ?? false
    }

    private var canManageReceiptLink: Bool {
        matchesStoredReceipt
            || version.linkedDeliveryReceiptID != nil
    }

    private var storedReceiptLinkMismatch: Bool {
        guard let storedReceipt else { return false }
        return version.linkedDeliveryReceiptID == storedReceipt.id
            && !version.matchesDeliveryReceipt(storedReceipt)
    }

    private var receiptLinkTitle: String {
        if matchesStoredReceipt {
            return model.record(id: recordID)?
                .hasCurrentDeliveryReceipt == true
                ? "Link current delivery receipt".localizedUI
                : "Link matching delivery receipt".localizedUI
        }
        if storedReceiptLinkMismatch {
            return "Receipt link mismatch".localizedUI
        }
        if version.linkedDeliveryReceiptID != nil {
            return "Keep archived receipt link".localizedUI
        }
        return "Link delivery receipt".localizedUI
    }

    private var receiptLinkDetail: String {
        if matchesStoredReceipt {
            return model.record(id: recordID)?
                .hasCurrentDeliveryReceipt == true
                ? "Revision ID and SHA-256 match this version.".localizedUI
                : "The working copy changed, but this version still matches the receipt."
                    .localizedUI
        }
        if storedReceiptLinkMismatch {
            return "Turn off this link to remove the mismatched receipt reference."
                .localizedUI
        }
        if version.linkedDeliveryReceiptID != nil {
            return "The original receipt is no longer stored with this working copy."
                .localizedUI
        }
        return "Only an exact receipt-matched version can be linked."
            .localizedUI
    }

    @ViewBuilder
    private var milestoneCapacityStatus: some View {
        if let capacityErrorMessage {
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                Label(
                    capacityErrorMessage.localizedUI,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.rose)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    capacityReloadRequest &+= 1
                } label: {
                    Label(
                        "Retry capacity check",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.cyan)
                )
                .accessibilityIdentifier(
                    "retryMilestoneCapacity"
                )
            }
        } else if !hasLoadedPinnedStorageSummary {
            Label(
                "Checking milestone capacity".localizedUI,
                systemImage: "hourglass"
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
        } else if isPinned, !version.isPinnedMilestone {
            let canAdd = hasLoadedPinnedStorageSummary
                && pinnedStorageSummary.canAdd(bytes: version.byteCount)
            Label(
                canAdd
                    ? AppLocalization.format(
                        "%@ available after this milestone",
                        ByteCountFormatter.string(
                            fromByteCount: max(
                                0,
                                pinnedStorageSummary.remainingByteCount
                                    - version.byteCount
                            ),
                            countStyle: .file
                        )
                    )
                    : hasLoadedPinnedStorageSummary
                        ? "Milestone storage is full. Unpin or archive an older milestone first."
                            .localizedUI
                        : "Checking milestone capacity".localizedUI,
                systemImage: canAdd
                    ? "internaldrive"
                    : hasLoadedPinnedStorageSummary
                        ? "externaldrive.badge.exclamationmark"
                        : "hourglass"
            )
            .font(.caption)
            .foregroundStyle(
                canAdd
                    ? PPColor.textSecondary
                    : hasLoadedPinnedStorageSummary
                        ? PPColor.rose
                        : PPColor.textSecondary
            )
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("milestoneCapacityStatus")
        } else if version.isPinnedMilestone {
            Label(
                "\(pinnedStorageSummary.countContract) · \(pinnedStorageSummary.byteContract)",
                systemImage: "pin.fill"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(PPColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cannotSaveMilestone: Bool {
        guard isPinned, !version.isPinnedMilestone else { return false }
        return !hasLoadedPinnedStorageSummary
            || !pinnedStorageSummary.canAdd(bytes: version.byteCount)
    }

    private var normalizedMilestoneName: String? {
        let trimmed = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }

    private var hasMilestoneChanges: Bool {
        normalizedMilestoneName != version.resolvedMilestoneName
            || (isPinned || linksDelivery)
                != version.isPinnedMilestone
            || linksDelivery
                != (version.linkedDeliveryReceiptID != nil)
    }

    private var milestoneSaveDisabledReason: String? {
        if isSaving {
            return "Wait for milestone saving to finish."
        }
        if !hasMilestoneChanges {
            return "Milestone settings are already saved."
        }
        guard cannotSaveMilestone else { return nil }
        if capacityErrorMessage != nil {
            return "Retry the capacity check before protecting this milestone."
        }
        if !hasLoadedPinnedStorageSummary {
            return "Wait for the milestone capacity check to finish."
        }
        return "Unpin or archive an older milestone first."
    }

    private func loadPinnedStorageSummary() async {
        hasLoadedPinnedStorageSummary = false
        capacityErrorMessage = nil
        let summary = await model.pinnedVersionStorageSummary()
        guard !Task.isCancelled else { return }
        guard let summary else {
            capacityErrorMessage =
                "Milestone capacity could not be checked. Try again."
            capacityErrorFeedback += 1
            return
        }
        pinnedStorageSummary = summary
        hasLoadedPinnedStorageSummary = true
    }

    private func save() {
        guard !isSaving,
              !cannotSaveMilestone,
              hasMilestoneChanges
        else { return }
        isNameFieldFocused = false
        saveErrorMessage = nil
        let generation = UUID()
        saveGeneration = generation
        isSaving = true
        saveStopRequested = false
        saveTask = Task { @MainActor in
            let updated = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.updateVersionMilestone(
                    recordID: recordID,
                    snapshotID: version.id,
                    name: name,
                    pinned: isPinned || linksDelivery,
                    linksCurrentDeliveryReceipt: linksDelivery
                )
            }
            guard saveGeneration == generation else { return }
            let wasStopped =
                saveStopRequested || Task.isCancelled
            isSaving = false
            saveTask = nil
            saveStopRequested = false
            if wasStopped {
                guard let updated else {
                    model[noticeFor: paperPathSceneID] =
                        "Milestone update stopped · changes not saved"
                            .localizedUI
                    return
                }
                model[noticeFor: paperPathSceneID] =
                    "Milestone update finished before stopping · changes kept"
                        .localizedUI
                onSave(updated)
                dismiss()
                return
            }
            guard let updated else {
                saveErrorMessage =
                    "The milestone could not be saved. Try again."
                        .localizedUI
                saveErrorFeedback += 1
                return
            }
            onSave(updated)
            dismiss()
        }
    }

    private func requestDismissal() {
        isNameFieldFocused = false
        if hasMilestoneChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func stopSaving() {
        guard saveTask != nil,
              !saveStopRequested
        else { return }
        saveStopRequested = true
        saveTask?.cancel()
    }

    private func invalidateMilestoneSave() {
        saveGeneration = UUID()
        saveTask?.cancel()
        saveTask = nil
        isSaving = false
        saveStopRequested = false
    }

    private func interruptProtectedMilestoneEditing() {
        invalidateMilestoneSave()
        name = ""
        dismiss()
    }
}

struct PDFComparisonProofConfiguration {
    let id: String
    let navigationTitle: String
    let evidenceLabel: String
    let sourceLabel: String
    let sourceTitle: String
    let sourceURL: URL
    let sourcePageCount: Int
    let sourceRefreshToken: Int
    let sourceSymbol: String
    let revisedLabel: String
    let revisedTitle: String
    let revisedURL: URL
    let revisedPageCount: Int
    let revisedRefreshToken: Int
    let revisedSymbol: String
    let initialSourcePageIndex: Int?
    let initialRevisedPageIndex: Int?
    let initialChangeIndex: Int?
    let recompute:
        (
            [PDFManualPageMatch],
            @escaping @MainActor @Sendable (
                PDFComparisonProgress
            ) -> Void
        ) async throws -> PDFChangeReview

    init(
        id: String,
        navigationTitle: String,
        evidenceLabel: String,
        sourceLabel: String,
        sourceTitle: String,
        sourceURL: URL,
        sourcePageCount: Int,
        sourceRefreshToken: Int,
        sourceSymbol: String,
        revisedLabel: String,
        revisedTitle: String,
        revisedURL: URL,
        revisedPageCount: Int,
        revisedRefreshToken: Int,
        revisedSymbol: String,
        initialSourcePageIndex: Int? = nil,
        initialRevisedPageIndex: Int? = nil,
        initialChangeIndex: Int? = nil,
        recompute: @escaping (
            [PDFManualPageMatch],
            @escaping @MainActor @Sendable (
                PDFComparisonProgress
            ) -> Void
        ) async throws -> PDFChangeReview
    ) {
        self.id = id
        self.navigationTitle = navigationTitle
        self.evidenceLabel = evidenceLabel
        self.sourceLabel = sourceLabel
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.sourcePageCount = sourcePageCount
        self.sourceRefreshToken = sourceRefreshToken
        self.sourceSymbol = sourceSymbol
        self.revisedLabel = revisedLabel
        self.revisedTitle = revisedTitle
        self.revisedURL = revisedURL
        self.revisedPageCount = revisedPageCount
        self.revisedRefreshToken = revisedRefreshToken
        self.revisedSymbol = revisedSymbol
        self.initialSourcePageIndex = initialSourcePageIndex
        self.initialRevisedPageIndex = initialRevisedPageIndex
        self.initialChangeIndex = initialChangeIndex
        self.recompute = recompute
    }
}

struct PDFComparisonProofView: View {
    private enum ChangeFilter:
        String,
        CaseIterable,
        Hashable,
        Identifiable {
        case all
        case critical
        case text
        case vector
        case pageStructure

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All changes"
            case .critical: return "Critical"
            case .text: return "Text"
            case .vector: return "Vector"
            case .pageStructure: return "Page structure"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "line.3.horizontal.decrease.circle"
            case .critical: return "exclamationmark.octagon"
            case .text: return "textformat"
            case .vector: return "square.dashed"
            case .pageStructure: return "doc.badge.plus"
            }
        }

        func includes(_ change: PDFPageChange) -> Bool {
            switch self {
            case .all:
                return true
            case .critical:
                return change.severity == .critical
            case .text:
                return change.textChanged
                    || change.hasLocatedTextDifferences
            case .vector:
                return change.hasLocatedVectorDifferences
            case .pageStructure:
                return change.resolvedMatchKind == .inserted
                    || change.resolvedMatchKind == .removed
                    || change.geometryChanged
            }
        }
    }

    private struct ChangeIndexSnapshot {
        let counts: [ChangeFilter: Int]
        let insertedCount: Int
        let removedCount: Int
        let locatedTextCount: Int

        static func build(
            for review: PDFChangeReview
        ) -> ChangeIndexSnapshot {
            var counts = Dictionary(
                uniqueKeysWithValues: ChangeFilter.allCases.map {
                    ($0, 0)
                }
            )
            var insertedCount = 0
            var removedCount = 0
            var locatedTextCount = 0

            for change in review.changes {
                for filter in ChangeFilter.allCases
                where filter.includes(change) {
                    counts[filter, default: 0] += 1
                }
                switch change.resolvedMatchKind {
                case .inserted:
                    insertedCount += 1
                case .removed:
                    removedCount += 1
                default:
                    break
                }
                if change.textChanged
                    && change.hasLocatedTextDifferences {
                    locatedTextCount += 1
                }
            }

            return ChangeIndexSnapshot(
                counts: counts,
                insertedCount: insertedCount,
                removedCount: removedCount,
                locatedTextCount: locatedTextCount
            )
        }
    }

    private struct PairingEditorPayload: Identifiable {
        let sourcePageIndex: Int
        let revisedPageIndex: Int
        let allowedRevisedRange: ClosedRange<Int>
        let hasExistingCorrection: Bool

        var id: Int { sourcePageIndex }
    }

    private enum PendingPairingAction {
        case apply(sourcePageIndex: Int, revisedPageIndex: Int)
        case reset(sourcePageIndex: Int)
    }

    private struct PairingRequest {
        let manualMatches: [PDFManualPageMatch]
        let sourcePageIndex: Int
        let revisedPageIndex: Int
    }

    private enum EvidenceLayer: CaseIterable, Hashable {
        case visual
        case text
        case vector

        var title: String {
            switch self {
            case .visual: return "Visual change regions"
            case .text: return "Text and character marks"
            case .vector: return "Vector boundaries"
            }
        }

        var symbol: String {
            switch self {
            case .visual: return "viewfinder"
            case .text: return "textformat"
            case .vector: return "square.dashed"
            }
        }
    }

    private enum ProofSide: String, CaseIterable, Identifiable {
        case saved
        case current

        var id: String { rawValue }

        var title: String {
            switch self {
            case .saved: return "Saved"
            case .current: return "Current"
            }
        }

        var symbol: String {
            switch self {
            case .saved: return "clock.arrow.circlepath"
            case .current: return "doc.fill"
            }
        }
    }

    private struct ProofPresentationSnapshot: Equatable {
        let syncPages: Bool
        let showsVisualEvidence: Bool
        let showsTextEvidence: Bool
        let showsVectorEvidence: Bool
        let proofSide: ProofSide
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("versionProof.snapshotID")
    private var savedSnapshotID = ""
    @SceneStorage("versionProof.savedPage")
    private var savedHistoricalPage = 0
    @SceneStorage("versionProof.currentPage")
    private var savedCurrentPage = 0
    @SceneStorage("versionProof.changeIndex")
    private var savedChangeIndex = 0
    @AppStorage("versionProof.syncPages")
    private var defaultSyncPages = true
    @AppStorage("versionProof.evidence")
    private var defaultShowsEvidence = true
    @AppStorage("versionProof.visualEvidence")
    private var defaultShowsVisualEvidence = true
    @AppStorage("versionProof.textEvidence")
    private var defaultShowsTextEvidence = true
    @AppStorage("versionProof.vectorEvidence")
    private var defaultShowsVectorEvidence = true
    @SceneStorage("versionProof.changeFilter")
    private var savedChangeFilter = ChangeFilter.all.rawValue
    @SceneStorage("versionProof.sceneSyncPages")
    private var savedSceneSyncPages = ""
    @SceneStorage("versionProof.sceneVisualEvidence")
    private var savedSceneVisualEvidence = ""
    @SceneStorage("versionProof.sceneTextEvidence")
    private var savedSceneTextEvidence = ""
    @SceneStorage("versionProof.sceneVectorEvidence")
    private var savedSceneVectorEvidence = ""
    @SceneStorage("versionProof.proofSide")
    private var savedProofSide = ProofSide.current.rawValue

    let configuration: PDFComparisonProofConfiguration
    let onReviewUpdated: (PDFChangeReview) -> Void

    @State private var review: PDFChangeReview
    @State private var historicalPage = 0
    @State private var currentPage = 0
    @State private var historicalNavigationToken = 0
    @State private var currentNavigationToken = 0
    @State private var selectedChangeIndex = 0
    @State private var selectedProofSide = ProofSide.current
    @State private var syncPages = true
    @State private var showsEvidence = true
    @State private var showsVisualEvidence = true
    @State private var showsTextEvidence = true
    @State private var showsVectorEvidence = true
    @State private var didRestoreProofPresentation = false
    @State private var lastProofPresentation:
        ProofPresentationSnapshot?
    @State private var pairingEditor: PairingEditorPayload?
    @State private var pendingPairingAction: PendingPairingAction?
    @State private var isConfirmingAutomaticPairing = false
    @State private var pairingTask: Task<Void, Never>?
    @State private var pairingGeneration = UUID()
    @State private var activePairingRequest: PairingRequest?
    @State private var failedPairingRequest: PairingRequest?
    @State private var isRecomputingPairing = false
    @State private var pairingProgress =
        PDFComparisonProgress.starting
    @State private var pairingError: String?
    @State private var pairingSuccessFeedback = 0
    @State private var pairingErrorFeedback = 0
    @State private var presentedTextEvidence: PDFPageChange?
    @State private var presentedVectorEvidence: PDFPageChange?
    @State private var pageMatchLookup: PDFPageMatchLookup
    @State private var filteredChangeIndices: [Int]
    @State private var changeIndexSnapshot: ChangeIndexSnapshot

    init(
        configuration: PDFComparisonProofConfiguration,
        review: PDFChangeReview,
        onReviewUpdated: @escaping (PDFChangeReview) -> Void
    ) {
        self.configuration = configuration
        self.onReviewUpdated = onReviewUpdated
        _review = State(initialValue: review)
        _pageMatchLookup = State(
            initialValue: PDFPageMatchLookup(review: review)
        )
        _filteredChangeIndices = State(
            initialValue: Array(review.changes.indices)
        )
        _changeIndexSnapshot = State(
            initialValue: ChangeIndexSnapshot.build(for: review)
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                proofWorkspace
            }
            .navigationTitle(
                configuration.navigationTitle.localizedUI
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Section("Show changes") {
                            Picker(
                                "Change filter",
                                selection: $savedChangeFilter
                            ) {
                                ForEach(ChangeFilter.allCases) {
                                    filter in
                                    Label(
                                        "\(filter.title.localizedUI) (\(changeCount(for: filter)))",
                                        systemImage: filter.symbol
                                    )
                                    .tag(filter.rawValue)
                                    .disabled(
                                        changeCount(for: filter) == 0
                                            && filter != .all
                                    )
                                }
                            }
                        }

                        if canAdjustSelectedPairing
                            || review.manualPageMatchCount > 0 {
                            Section("Page pairing") {
                                if canAdjustSelectedPairing {
                                    Button {
                                        presentPairingEditor()
                                    } label: {
                                        Label(
                                            "Correct Page Match",
                                            systemImage:
                                                "arrow.left.arrow.right"
                                        )
                                    }
                                }
                                if review.manualPageMatchCount > 0 {
                                    Button {
                                        isConfirmingAutomaticPairing =
                                            true
                                    } label: {
                                        Label(
                                            "Use Automatic Pairing",
                                            systemImage:
                                                "arrow.counterclockwise"
                                        )
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(
                            systemName:
                                review.manualPageMatchCount > 0
                                    ? "line.3.horizontal.decrease.circle.fill"
                                    : selectedChangeFilter.symbol
                        )
                    }
                    .disabled(
                        review.changes.isEmpty
                            || isRecomputingPairing
                    )
                    .help("Review changes")
                    .accessibilityLabel("Review changes")
                    .accessibilityValue(
                        AppLocalization.format(
                            "%@, %lld of %lld changes",
                            selectedChangeFilter.title.localizedUI,
                            filteredChangeIndices.count,
                            review.changes.count
                        )
                    )

                    Toggle(isOn: $syncPages) {
                        Image(systemName: "link")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help("Pages move together")
                    .disabled(isRecomputingPairing)
                    .accessibilityLabel("Keep saved and current pages linked")

                    Menu {
                        Button {
                            setAllEvidenceLayers(
                                visible: !hasVisibleEvidenceLayer
                            )
                        } label: {
                            Label(
                                hasVisibleEvidenceLayer
                                    ? "Hide All Evidence"
                                    : "Show All Evidence",
                                systemImage: hasVisibleEvidenceLayer
                                    ? "eye.slash"
                                    : "eye"
                            )
                        }

                        Section("Evidence layers") {
                            ForEach(
                                EvidenceLayer.allCases,
                                id: \.self
                            ) { layer in
                                Toggle(
                                    isOn: evidenceBinding(for: layer)
                                ) {
                                    Label(
                                        layer.title.localizedUI,
                                        systemImage: layer.symbol
                                    )
                                }
                            }
                        }
                    } label: {
                        Image(
                            systemName: hasVisibleEvidenceLayer
                                ? "square.stack.3d.up.fill"
                                : "square.stack.3d.up"
                        )
                    }
                    .disabled(isRecomputingPairing)
                    .help("Evidence layers")
                    .accessibilityLabel("Evidence layers")
                    .accessibilityValue(
                        evidenceLayerAccessibilityValue
                    )

                    Button(
                        (
                            isRecomputingPairing
                                ? "Stop"
                                : "Done"
                        ).localizedUI
                    ) {
                        if isRecomputingPairing {
                            stopPairingRecomputation()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                proofCommandBar
            }
        }
        .onAppear {
            restoreProofPresentationIfNeeded()
            normalizeEvidenceLayerState()
            restoreState()
            rebuildFilteredChangeIndices()
            normalizeChangeSelection()
        }
        .onChange(of: historicalPage) { _, page in
            savedSnapshotID = configuration.id
            savedHistoricalPage = page
        }
        .onChange(of: currentPage) { _, page in
            savedSnapshotID = configuration.id
            savedCurrentPage = page
        }
        .onChange(of: selectedChangeIndex) { _, index in
            savedSnapshotID = configuration.id
            savedChangeIndex = index
        }
        .onChange(of: savedChangeFilter) { _, _ in
            rebuildFilteredChangeIndices()
            normalizeChangeSelection()
        }
        .onChange(of: proofPresentationSnapshot) { _, snapshot in
            persistProofPresentationIfNeeded(snapshot)
        }
        .onDisappear {
            stopPairingRecomputation(offersRetry: false)
            pendingPairingAction = nil
            activePairingRequest = nil
            failedPairingRequest = nil
            presentedTextEvidence = nil
            presentedVectorEvidence = nil
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptProtectedProof()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtectedProof()
        }
        .interactiveDismissDisabled(isRecomputingPairing)
        .accessibilityAction(.escape) {
            if isRecomputingPairing {
                stopPairingRecomputation()
            } else {
                dismiss()
            }
        }
        .confirmationDialog(
            "Remove all saved page matches?",
            isPresented: $isConfirmingAutomaticPairing,
            titleVisibility: .visible
        ) {
            Button("Remove Saved Matches", role: .destructive) {
                recomputePairing(
                    manualMatches: [],
                    sourcePageIndex: historicalPage,
                    revisedPageIndex: currentPage
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                AppLocalization.format(
                    "%lld manual page match%@ will be removed from this device.",
                    review.manualPageMatchCount,
                    review.manualPageMatchCount == 1 ? "" : "es"
                )
            )
        }
        .sheet(
            item: $pairingEditor,
            onDismiss: completePairingEditorAction
        ) { payload in
            PDFPagePairingEditor(
                sourceURL: configuration.sourceURL,
                revisedURL: configuration.revisedURL,
                sourceLabel: configuration.sourceLabel,
                sourceTitle: configuration.sourceTitle,
                revisedTitle: configuration.revisedTitle,
                sourcePageIndex: payload.sourcePageIndex,
                revisedPageIndex: payload.revisedPageIndex,
                sourcePageCount: configuration.sourcePageCount,
                revisedPageCount: review.revisedPageCount,
                allowedRevisedRange: payload.allowedRevisedRange,
                revisedRefreshToken:
                    configuration.revisedRefreshToken,
                hasExistingCorrection:
                    payload.hasExistingCorrection,
                onApply: { revisedPageIndex in
                    pendingPairingAction = .apply(
                        sourcePageIndex: payload.sourcePageIndex,
                        revisedPageIndex: revisedPageIndex
                    )
                    pairingEditor = nil
                },
                onReset: payload.hasExistingCorrection
                    ? {
                        pendingPairingAction = .reset(
                            sourcePageIndex:
                                payload.sourcePageIndex
                        )
                        pairingEditor = nil
                    }
                    : nil
            )
        }
        .sheet(item: $presentedTextEvidence) { change in
            PDFTextEvidenceDetailView(
                change: change,
                sourceLabel: configuration.sourceLabel,
                revisedLabel: configuration.revisedLabel
            )
        }
        .sheet(item: $presentedVectorEvidence) { change in
            PDFVectorEvidenceDetailView(
                change: change,
                sourceLabel: configuration.sourceLabel,
                revisedLabel: configuration.revisedLabel,
                isLayerVisible: showsVectorEvidence,
                onReveal: {
                    revealVectorEvidence(for: change)
                }
            )
        }
        .sensoryFeedback(.selection, trigger: selectedChangeIndex)
        .sensoryFeedback(.selection, trigger: selectedProofSide)
        .sensoryFeedback(.selection, trigger: savedChangeFilter)
        .sensoryFeedback(
            .success,
            trigger: pairingSuccessFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: pairingErrorFeedback
        )
    }

    private var usesCompactProofLayout: Bool {
        horizontalSizeClass == .compact
            || dynamicTypeSize.ppPrefersExpandedLayout
    }

    private var hasVisibleEvidenceLayer: Bool {
        showsVisualEvidence
            || showsTextEvidence
            || showsVectorEvidence
    }

    private var evidenceLayerAccessibilityValue: String {
        let visibleLayers = EvidenceLayer.allCases.filter(
            isEvidenceLayerVisible
        )
        if visibleLayers.isEmpty {
            return "Evidence hidden".localizedUI
        }
        if visibleLayers.count == EvidenceLayer.allCases.count {
            return "All evidence layers".localizedUI
        }
        return visibleLayers
            .map { $0.title.localizedUI }
            .joined(separator: " · ")
    }

    private func evidenceBinding(
        for layer: EvidenceLayer
    ) -> Binding<Bool> {
        Binding(
            get: {
                isEvidenceLayerVisible(layer)
            },
            set: { visible in
                setEvidenceLayer(layer, visible: visible)
            }
        )
    }

    private func isEvidenceLayerVisible(
        _ layer: EvidenceLayer
    ) -> Bool {
        switch layer {
        case .visual: return showsVisualEvidence
        case .text: return showsTextEvidence
        case .vector: return showsVectorEvidence
        }
    }

    private func setEvidenceLayer(
        _ layer: EvidenceLayer,
        visible: Bool
    ) {
        switch layer {
        case .visual:
            showsVisualEvidence = visible
        case .text:
            showsTextEvidence = visible
        case .vector:
            showsVectorEvidence = visible
        }
        showsEvidence = hasVisibleEvidenceLayer
    }

    private func setAllEvidenceLayers(visible: Bool) {
        showsVisualEvidence = visible
        showsTextEvidence = visible
        showsVectorEvidence = visible
        showsEvidence = visible
    }

    private func normalizeEvidenceLayerState() {
        if !showsEvidence {
            setAllEvidenceLayers(visible: false)
        } else if !hasVisibleEvidenceLayer {
            setAllEvidenceLayers(visible: true)
        }
    }

    private var proofPresentationSnapshot:
        ProofPresentationSnapshot {
        ProofPresentationSnapshot(
            syncPages: syncPages,
            showsVisualEvidence: showsVisualEvidence,
            showsTextEvidence: showsTextEvidence,
            showsVectorEvidence: showsVectorEvidence,
            proofSide: selectedProofSide
        )
    }

    private func restoreProofPresentationIfNeeded() {
        guard !didRestoreProofPresentation else { return }
        let hasSceneEvidencePreferences =
            storedBool(savedSceneVisualEvidence) != nil
                || storedBool(savedSceneTextEvidence) != nil
                || storedBool(savedSceneVectorEvidence) != nil
        syncPages =
            storedBool(savedSceneSyncPages) ?? defaultSyncPages
        if hasSceneEvidencePreferences {
            showsVisualEvidence =
                storedBool(savedSceneVisualEvidence)
                    ?? defaultShowsVisualEvidence
            showsTextEvidence =
                storedBool(savedSceneTextEvidence)
                    ?? defaultShowsTextEvidence
            showsVectorEvidence =
                storedBool(savedSceneVectorEvidence)
                    ?? defaultShowsVectorEvidence
        } else if defaultShowsEvidence {
            showsVisualEvidence = defaultShowsVisualEvidence
            showsTextEvidence = defaultShowsTextEvidence
            showsVectorEvidence = defaultShowsVectorEvidence
            if !hasVisibleEvidenceLayer {
                showsVisualEvidence = true
                showsTextEvidence = true
                showsVectorEvidence = true
            }
        } else {
            showsVisualEvidence = false
            showsTextEvidence = false
            showsVectorEvidence = false
        }
        showsEvidence = hasVisibleEvidenceLayer
        selectedProofSide =
            ProofSide(rawValue: savedProofSide) ?? .current
        let snapshot = proofPresentationSnapshot
        lastProofPresentation = snapshot
        didRestoreProofPresentation = true
        persistProofPresentation(
            snapshot,
            updatesDefaults: false
        )
    }

    private func persistProofPresentationIfNeeded(
        _ snapshot: ProofPresentationSnapshot
    ) {
        guard didRestoreProofPresentation,
              lastProofPresentation != snapshot
        else { return }
        lastProofPresentation = snapshot
        showsEvidence =
            snapshot.showsVisualEvidence
                || snapshot.showsTextEvidence
                || snapshot.showsVectorEvidence
        persistProofPresentation(
            snapshot,
            updatesDefaults: true
        )
    }

    private func persistProofPresentation(
        _ snapshot: ProofPresentationSnapshot,
        updatesDefaults: Bool
    ) {
        savedSceneSyncPages = storedString(snapshot.syncPages)
        savedSceneVisualEvidence =
            storedString(snapshot.showsVisualEvidence)
        savedSceneTextEvidence =
            storedString(snapshot.showsTextEvidence)
        savedSceneVectorEvidence =
            storedString(snapshot.showsVectorEvidence)
        savedProofSide = snapshot.proofSide.rawValue
        guard updatesDefaults else { return }
        defaultSyncPages = snapshot.syncPages
        defaultShowsVisualEvidence =
            snapshot.showsVisualEvidence
        defaultShowsTextEvidence =
            snapshot.showsTextEvidence
        defaultShowsVectorEvidence =
            snapshot.showsVectorEvidence
        defaultShowsEvidence =
            snapshot.showsVisualEvidence
                || snapshot.showsTextEvidence
                || snapshot.showsVectorEvidence
    }

    private func storedBool(_ value: String) -> Bool? {
        switch value {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private func storedString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func revealVectorEvidence(
        for change: PDFPageChange
    ) {
        setEvidenceLayer(.vector, visible: true)
        guard usesCompactProofLayout else { return }
        let hasSourceBounds =
            !(change.sourceVectorDifferences ?? []).isEmpty
        let hasRevisedBounds =
            !(change.revisedVectorDifferences ?? []).isEmpty
        if selectedProofSide == .saved, !hasSourceBounds,
           hasRevisedBounds {
            selectedProofSide = .current
        } else if selectedProofSide == .current,
                  !hasRevisedBounds,
                  hasSourceBounds {
            selectedProofSide = .saved
        }
    }

    @ViewBuilder
    private var proofWorkspace: some View {
        if usesCompactProofLayout {
            compactProofWorkspace
        } else {
            regularProofWorkspace
        }
    }

    private var regularProofWorkspace: some View {
        HStack(spacing: 0) {
            revisionRail
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(width: 1)
            savedProofPane
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(width: 1)
            currentProofPane
        }
    }

    private var compactProofWorkspace: some View {
        VStack(spacing: 0) {
            let picker = Picker(
                "Revision side",
                selection: $selectedProofSide
            ) {
                ForEach(ProofSide.allCases) { side in
                    Label(
                        side == .saved
                            ? configuration.sourceLabel.localizedUI
                            : configuration.revisedLabel.localizedUI,
                        systemImage: side == .saved
                            ? configuration.sourceSymbol
                            : configuration.revisedSymbol
                    )
                    .tag(side)
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
                    .padding(.horizontal, PPSpacing.regular)
                    .padding(.vertical, PPSpacing.small)
                    .background(.bar)
                    .accessibilityIdentifier(
                        "revisionProofSide"
                    )
            } else {
                picker
                    .pickerStyle(.segmented)
                    .padding(.horizontal, PPSpacing.regular)
                    .padding(.vertical, PPSpacing.small)
                    .background(.bar)
                    .accessibilityIdentifier(
                        "revisionProofSide"
                    )
            }

            compactRevisionRail

            switch selectedProofSide {
            case .saved:
                savedProofPane
            case .current:
                currentProofPane
            }
        }
    }

    private var savedProofPane: some View {
        proofPane(
            label: configuration.sourceLabel,
            title: configuration.sourceTitle,
            url: configuration.sourceURL,
            page: historicalPage,
            pageCount: configuration.sourcePageCount,
            refreshToken: configuration.sourceRefreshToken,
            navigationToken: historicalNavigationToken,
            tone: .source
        ) { page in
            historicalPageChanged(page)
        }
    }

    private var currentProofPane: some View {
        proofPane(
            label: configuration.revisedLabel,
            title: configuration.revisedTitle,
            url: configuration.revisedURL,
            page: currentPage,
            pageCount: configuration.revisedPageCount,
            refreshToken: configuration.revisedRefreshToken,
            navigationToken: currentNavigationToken,
            tone: .revised
        ) { page in
            currentPageChanged(page)
        }
    }

    private var selectedChange: PDFPageChange? {
        guard review.changes.indices.contains(
            selectedChangeIndex
        ),
              selectedChangeFilter.includes(
                  review.changes[selectedChangeIndex]
              )
        else {
            return filteredChangeIndices.first.map {
                review.changes[$0]
            }
        }
        return review.changes[selectedChangeIndex]
    }

    private var selectedChangeFilter: ChangeFilter {
        ChangeFilter(rawValue: savedChangeFilter) ?? .all
    }

    private func changeCount(for filter: ChangeFilter) -> Int {
        changeIndexSnapshot.counts[filter, default: 0]
    }

    private var canAdjustSelectedPairing: Bool {
        guard let selectedChange,
              selectedChange.resolvedSourcePageIndex != nil,
              selectedChange.resolvedRevisedPageIndex != nil
        else { return false }
        return selectedChange.matchBasis == .similarity
            || selectedChange.matchBasis == .repeatedContent
            || selectedChange.matchBasis == .manual
    }

    private var revisionRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(configuration.evidenceLabel.localizedUI)
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                Spacer(minLength: 0)
                Text(
                    filteredChangeIndices.count == review.changes.count
                        ? "\(review.changes.count)"
                        : "\(filteredChangeIndices.count)/\(review.changes.count)"
                )
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.rose)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(minHeight: 38)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(
                            filteredChangeIndices,
                            id: \.self
                        ) { index in
                            let change = review.changes[index]
                            Button {
                                selectedChangeIndex = index
                                open(change)
                            } label: {
                                revisionRailLabel(
                                    change,
                                    isSelected:
                                        index == selectedChangeIndex
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isRecomputingPairing)
                            .id(index)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(pagePair(change))
                            .accessibilityValue(
                                revisionEvidenceDetail(change)
                            )
                            .accessibilityAddTraits(
                                index == selectedChangeIndex
                                    ? .isSelected
                                    : []
                            )
                        }
                    }
                }
                .onAppear {
                    scrollToSelectedChange(using: proxy)
                }
                .onChange(of: selectedChangeIndex) { _, _ in
                    scrollToSelectedChange(using: proxy)
                }
                .onChange(of: savedChangeFilter) { _, _ in
                    scrollToSelectedChange(using: proxy)
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 190)
        .background(PPColor.elevated.opacity(0.78))
    }

    @ViewBuilder
    private var compactRevisionRail: some View {
        if filteredChangeIndices.isEmpty {
            Label(
                review.changes.isEmpty
                    ? "No deterministic changes".localizedUI
                    : "No changes in this filter".localizedUI,
                systemImage: review.changes.isEmpty
                    ? "checkmark.circle"
                    : "line.3.horizontal.decrease.circle"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.mint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(PPColor.elevated.opacity(0.78))
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: PPSpacing.small) {
                        ForEach(filteredChangeIndices, id: \.self) { index in
                            compactRevisionButton(
                                index: index,
                                change: review.changes[index]
                            )
                            .id(index)
                        }
                    }
                    .padding(.horizontal, PPSpacing.small)
                    .padding(.vertical, 6)
                }
                .onAppear {
                    scrollToSelectedChange(using: proxy)
                }
                .onChange(of: selectedChangeIndex) { _, _ in
                    scrollToSelectedChange(using: proxy)
                }
                .onChange(of: savedChangeFilter) { _, _ in
                    scrollToSelectedChange(using: proxy)
                }
            }
            .background(PPColor.elevated.opacity(0.78))
        }
    }

    private func revisionRailLabel(
        _ change: PDFPageChange,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Image(
                systemName: change.resolvedMatchKind == .inserted
                    ? "plus.circle"
                    : change.resolvedMatchKind == .removed
                        ? "minus.circle"
                        : "viewfinder.circle"
            )
            .foregroundStyle(
                change.severity == .critical
                    ? PPColor.rose
                    : PPColor.amber
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(pagePair(change))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(revisionEvidenceDetail(change))
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PPSpacing.small)
        .frame(minHeight: 48)
        .background(
            isSelected
                ? PPColor.amber.opacity(0.07)
                : Color.clear
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? PPColor.amber : PPColor.border)
                .frame(width: isSelected ? 2 : 0.6)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.48))
                .frame(height: 0.6)
        }
        .contentShape(Rectangle())
    }

    private func compactRevisionButton(
        index: Int,
        change: PDFPageChange
    ) -> some View {
        let isSelected = index == selectedChangeIndex
        return Button {
            selectedChangeIndex = index
            open(change)
        } label: {
            compactRevisionLabel(
                change,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .disabled(isRecomputingPairing)
        .accessibilityLabel(pagePair(change))
        .accessibilityValue(revisionEvidenceDetail(change))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func compactRevisionLabel(
        _ change: PDFPageChange,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pagePair(change))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
            Text(revisionEvidenceDetail(change))
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? 2
                        : 1
                )
                .truncationMode(.middle)
        }
        .frame(
            width: dynamicTypeSize.ppPrefersExpandedLayout
                ? 196
                : 132,
            alignment: .leading
        )
        .frame(minHeight: 44, alignment: .leading)
        .padding(.horizontal, PPSpacing.small)
        .background(
            isSelected
                ? PPColor.amber.opacity(0.09)
                : PPColor.surface
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(
                    isSelected
                        ? PPColor.amber
                        : PPColor.border.opacity(0.58)
                )
                .frame(height: isSelected ? 2 : 0.6)
        }
        .contentShape(Rectangle())
    }

    private func proofPane(
        label: String,
        title: String,
        url: URL,
        page: Int,
        pageCount: Int,
        refreshToken: Int,
        navigationToken: Int,
        tone: PDFEvidenceOverlayTone,
        onPageChange: @escaping (Int) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    proofPaneIdentity(
                        label: label,
                        title: title,
                        tone: tone,
                        titleLineLimit: 1
                    )
                    Spacer(minLength: 0)
                    proofPagePosition(page: page, pageCount: pageCount)
                }

                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    proofPaneIdentity(
                        label: label,
                        title: title,
                        tone: tone,
                        titleLineLimit: nil
                    )
                    proofPagePosition(page: page, pageCount: pageCount)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, PPSpacing.small)
            .padding(.vertical, PPSpacing.xSmall)
            .frame(minHeight: 38, alignment: .leading)
            .background(PPColor.surface.opacity(0.92))

            PDFDocumentView(
                url: url,
                refreshToken: refreshToken,
                targetPageIndex: page,
                navigationToken: navigationToken,
                readingPreferences: PDFReadingPreferences(
                    theme: .paper,
                    layout: .singlePage,
                    scrollsHorizontally: true
                ),
                evidenceOverlay: evidenceOverlay(
                    tone: tone,
                    page: page
                ),
                onPageChange: onPageChange
            )
            .background(PPColor.surfaceMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func proofPaneIdentity(
        label: String,
        title: String,
        tone: PDFEvidenceOverlayTone,
        titleLineLimit: Int?
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Text(label.localizedUI)
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(
                    tone == .source
                        ? PPColor.cyan
                        : PPColor.amber
                )
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(titleLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func proofPagePosition(
        page: Int,
        pageCount: Int
    ) -> some View {
        Text("\(page + 1) / \(max(pageCount, 1))")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(PPColor.textSecondary)
    }

    private var proofCommandBar: some View {
        VStack(
            alignment: .leading,
            spacing: usesCompactProofLayout ? 6 : 4
        ) {
            if isRecomputingPairing {
                HStack(spacing: PPSpacing.small) {
                    LocalComparisonProgressView(
                        progress: pairingProgress,
                        tint: PPColor.amber,
                        compact: true
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        stopPairingRecomputation()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.amber)
                    .accessibilityLabel(
                        "Stop comparison".localizedUI
                    )
                    .accessibilityHint(
                        "Keeps this page-match request available to retry."
                            .localizedUI
                    )
                }
            } else if let pairingError {
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
                    Label(
                        pairingError.localizedUI,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.amber)
                    .fixedSize(horizontal: false, vertical: true)

                    if failedPairingRequest != nil {
                        Button {
                            retryFailedPairing()
                        } label: {
                            Label(
                                "Retry Page Match",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(
                            PPQuietButtonStyle(tint: PPColor.amber)
                        )
                        .accessibilityIdentifier(
                            "retryPageMatchComparison"
                        )
                    }
                }
            }
            pairingPersistenceSummary
            selectedPageMatchSummary
            selectedVectorEvidenceSummary
            selectedTextEvidenceSummary

            if usesCompactProofLayout {
                VStack(spacing: 5) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        proofMetrics
                    }
                    HStack(spacing: PPSpacing.medium) {
                        changePosition
                        Spacer(minLength: 0)
                        changeNavigation
                    }
                }
            } else {
                HStack(spacing: PPSpacing.medium) {
                    proofMetrics
                    Spacer(minLength: 0)
                    changePosition
                    changeNavigation
                }
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, usesCompactProofLayout ? 6 : 0)
        .frame(minHeight: 44)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    @ViewBuilder
    private var pairingPersistenceSummary: some View {
        if review.manualPageMatchCount > 0,
           let persistence =
            review.manualPageMatchPersistence {
            Label(
                AppLocalization.format(
                    persistence == .restoredFromDevice
                        ? "%lld saved page match%@ restored on this device"
                        : "%lld page match%@ saved on this device",
                    review.manualPageMatchCount,
                    review.manualPageMatchCount == 1 ? "" : "es"
                ),
                systemImage:
                    persistence == .restoredFromDevice
                        ? "clock.arrow.circlepath"
                        : "internaldrive"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.mint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHint(
                "Only document identifiers, revision identifiers, and page numbers are retained."
                    .localizedUI
            )
        }
    }

    @ViewBuilder
    private var selectedPageMatchSummary: some View {
        if let basis = selectedChange?.matchBasis {
            Label {
                ViewThatFits(in: .horizontal) {
                    Text(
                        AppLocalization.format(
                            "%@ · %@",
                            basis.title.localizedUI,
                            basis.evidenceDetail.localizedUI
                        )
                    )
                    Text(basis.evidenceDetail.localizedUI)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: basis.symbol)
                    .foregroundStyle(
                        basis == .similarity
                            ? PPColor.amber
                            : PPColor.cyan
                    )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                AppLocalization.format(
                    "Page match: %@. %@",
                    basis.title.localizedUI,
                    basis.evidenceDetail.localizedUI
                )
            )
        }
    }

    @ViewBuilder
    private var selectedVectorEvidenceSummary: some View {
        if let selectedChange,
           selectedChange.hasLocatedVectorDifferences {
            Button {
                presentedTextEvidence = nil
                presentedVectorEvidence = selectedChange
            } label: {
                HStack(spacing: PPSpacing.xSmall) {
                    Label(
                        selectedChange
                            .localizedVectorEvidenceCountLabel,
                        systemImage: "square.dashed"
                    )
                    .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    evidenceDisclosureIndicator
                }
                .foregroundStyle(PPColor.cyan)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRecomputingPairing)
            .accessibilityLabel(
                AppLocalization.format(
                    "%lld vector boundaries on this page",
                    selectedChange.vectorDifferenceCount
                )
            )
            .accessibilityHint(
                "Opens retained vector boundaries and their page locations."
                    .localizedUI
            )
        }
    }


    @ViewBuilder
    private var selectedTextEvidenceSummary: some View {
        if let selectedChange,
           selectedChange.hasLocatedTextDifferences {
            textEvidenceSummary(for: selectedChange)
        }
    }

    private func textEvidenceSummary(
        for change: PDFPageChange
    ) -> some View {
        let removedPreview = proofEvidencePreview(
            change.sourceTextDifferences
        )
        let insertedPreview = proofEvidencePreview(
            change.revisedTextDifferences
        )
        let title = change.hasCharacterDifferences
            ? "Character evidence"
            : "Text evidence"
        let count = change.localizedTextEvidenceCountLabel
        return Button {
            presentedVectorEvidence = nil
            presentedTextEvidence = change
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    evidenceSummaryHeader(
                        title: title,
                        count: count,
                        characterLevel: change.hasCharacterDifferences
                    )
                    Spacer(minLength: PPSpacing.medium)
                    if let removedPreview {
                        proofEvidenceToken(
                            title: "Removed text",
                            value: removedPreview,
                            tint: PPColor.rose
                        )
                    }
                    if let insertedPreview {
                        proofEvidenceToken(
                            title: "Inserted text",
                            value: insertedPreview,
                            tint: PPColor.mint
                        )
                    }
                    evidenceDisclosureIndicator
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: PPSpacing.xSmall) {
                        evidenceSummaryHeader(
                            title: title,
                            count: count,
                            characterLevel:
                                change.hasCharacterDifferences
                        )
                        Spacer(minLength: 0)
                        evidenceDisclosureIndicator
                    }
                    if let removedPreview {
                        proofEvidenceToken(
                            title: "Removed text",
                            value: removedPreview,
                            tint: PPColor.rose
                        )
                    }
                    if let insertedPreview {
                        proofEvidenceToken(
                            title: "Inserted text",
                            value: insertedPreview,
                            tint: PPColor.mint
                        )
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isRecomputingPairing)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            textEvidenceAccessibilityLabel(
                title: title,
                count: count,
                removedPreview: removedPreview,
                insertedPreview: insertedPreview
            )
        )
        .accessibilityHint(
            "Opens retained text evidence for selection and copying."
                .localizedUI
        )
    }

    private func evidenceSummaryHeader(
        title: String,
        count: String,
        characterLevel: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Image(
                systemName: characterLevel
                    ? "textformat"
                    : "text.quote"
            )
            .foregroundStyle(
                characterLevel ? PPColor.amber : PPColor.accent
            )
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
            Text(count)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .accessibilityHidden(true)
    }

    private func proofEvidenceToken(
        title: String,
        value: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 4) {
            Text(title.localizedUI.uppercased())
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption2)
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(0.2), lineWidth: 0.6)
        }
    }

    private var evidenceDisclosureIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(PPColor.textSecondary)
            .frame(width: 18, height: 24)
            .accessibilityHidden(true)
    }

    private func textEvidenceAccessibilityLabel(
        title: String,
        count: String,
        removedPreview: String?,
        insertedPreview: String?
    ) -> String {
        var parts = [title.localizedUI, count]
        if let removedPreview {
            parts.append(
                AppLocalization.format(
                    "Removed text: %@",
                    removedPreview
                )
            )
        }
        if let insertedPreview {
            parts.append(
                AppLocalization.format(
                    "Inserted text: %@",
                    insertedPreview
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    private func proofEvidencePreview(
        _ evidence: [PDFTextDifferenceEvidence]?
    ) -> String? {
        guard let evidence else { return nil }
        let characterEvidence = evidence.filter {
            $0.resolvedGranularity == .character
        }
        let preferredEvidence = characterEvidence.isEmpty
            ? evidence
            : characterEvidence
        let snippets = preferredEvidence
            .prefix(4)
            .map {
                compactProofEvidenceText(
                    $0.text,
                    granularity: $0.resolvedGranularity
                )
            }
            .filter { !$0.isEmpty }
        guard !snippets.isEmpty else { return nil }
        let omitted = preferredEvidence.count - snippets.count
        let summary = snippets.joined(separator: " · ")
        return omitted > 0 ? "\(summary) +\(omitted)" : summary
    }

    private func compactProofEvidenceText(
        _ value: String,
        granularity: PDFTextDifferenceGranularity
    ) -> String {
        let compacted = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let visible = compacted.isEmpty && !value.isEmpty
            ? visibleWhitespacePreview(value)
            : compacted
        let limit = granularity == .character ? 24 : 54
        guard visible.count > limit else { return visible }
        return String(visible.prefix(max(0, limit - 3))) + "..."
    }

    private func visibleWhitespacePreview(_ value: String) -> String {
        value.map { character -> String in
            switch character {
            case " ": return "␠"
            case "\n", "\r": return "↵"
            case "\t": return "⇥"
            default: return String(character)
            }
        }
        .joined()
    }

    private var proofMetrics: some View {
        HStack(spacing: PPSpacing.medium) {
            revisionMetric(
                value: "\(changeCount(for: .critical))",
                label: "Critical",
                tint: PPColor.rose
            )
            revisionMetric(
                value: "\(changeIndexSnapshot.insertedCount)",
                label: "Inserted",
                tint: PPColor.cyan
            )
            revisionMetric(
                value: "\(changeIndexSnapshot.removedCount)",
                label: "Removed",
                tint: PPColor.amber
            )
            revisionMetric(
                value: "\(changeIndexSnapshot.locatedTextCount)",
                label: "Text",
                tint: PPColor.accent
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var changePosition: some View {
        let visibleIndices = filteredChangeIndices
        let visiblePosition = filteredPosition(
            of: selectedChangeIndex
        )
        return Text(
            visibleIndices.isEmpty
                ? "No deterministic changes".localizedUI
                : "\(min((visiblePosition ?? 0) + 1, visibleIndices.count)) / \(visibleIndices.count)"
        )
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
    }

    private var changeNavigation: some View {
        HStack(spacing: PPSpacing.small) {
            Button {
                moveChange(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(filteredChangeIndices.isEmpty)
            .disabled(isRecomputingPairing)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityLabel("Previous change")

            Button {
                moveChange(1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(filteredChangeIndices.isEmpty)
            .disabled(isRecomputingPairing)
            .keyboardShortcut("]", modifiers: .command)
            .accessibilityLabel("Next change")
        }
    }

    private func evidenceOverlay(
        tone: PDFEvidenceOverlayTone,
        page: Int
    ) -> PDFEvidenceOverlay? {
        guard showsEvidence,
              hasVisibleEvidenceLayer,
              let selectedChange,
              !(selectedChange.differenceRegions ?? []).isEmpty
                || selectedChange.hasLocatedTextDifferences
                || selectedChange.hasLocatedVectorDifferences
        else { return nil }
        let expected = tone == .source
            ? selectedChange.resolvedSourcePageIndex
            : selectedChange.resolvedRevisedPageIndex
        guard expected == page else { return nil }
        let textEvidence = (
            tone == .source
                ? selectedChange.sourceTextDifferences
                : selectedChange.revisedTextDifferences
        ) ?? []
        let vectorEvidence = (
            tone == .source
                ? selectedChange.sourceVectorDifferences
                : selectedChange.revisedVectorDifferences
        ) ?? []
        return PDFEvidenceOverlay(
            pageIndex: page,
            regions: showsVisualEvidence
                ? selectedChange.differenceRegions ?? []
                : [],
            textRegions: showsTextEvidence
                ? textEvidence.filter {
                    $0.resolvedGranularity == .word
                }.map(\.region)
                : [],
            characterTextRegions: showsTextEvidence
                ? textEvidence.filter {
                    $0.resolvedGranularity == .character
                }.map(\.region)
                : [],
            vectorRegions: showsVectorEvidence
                ? vectorEvidence.map(\.region)
                : [],
            tone: tone,
            generation: selectedChangeIndex
        )
    }

    private func revisionEvidenceDetail(
        _ change: PDFPageChange
    ) -> String {
        var parts = [
            change.resolvedMatchKind.title.localizedUI,
            change.severity.title.localizedUI
        ]
        if change.hasLocatedTextDifferences {
            parts.append(change.localizedTextEvidenceCountLabel)
            if let preview = change.textDifferencePreview {
                parts.append(preview)
            }
        }
        if change.hasLocatedVectorDifferences {
            parts.append(change.localizedVectorEvidenceCountLabel)
        }
        if let matchBasis = change.matchBasis {
            parts.append(matchBasis.evidenceDetail.localizedUI)
        }
        return parts.joined(separator: " · ")
    }

    private func presentPairingEditor() {
        failedPairingRequest = nil
        pairingError = nil
        guard let selectedChange,
              let sourcePageIndex =
                selectedChange.resolvedSourcePageIndex,
              let revisedPageIndex =
                selectedChange.resolvedRevisedPageIndex
        else { return }
        guard let allowedRange = allowedRevisedRange(
            for: sourcePageIndex
        ) else {
            pairingError =
                "No ordered page remains available for this match."
            pairingErrorFeedback += 1
            return
        }
        pairingEditor = PairingEditorPayload(
            sourcePageIndex: sourcePageIndex,
            revisedPageIndex: min(
                allowedRange.upperBound,
                max(allowedRange.lowerBound, revisedPageIndex)
            ),
            allowedRevisedRange: allowedRange,
            hasExistingCorrection:
                selectedChange.matchBasis == .manual
        )
    }

    private func completePairingEditorAction() {
        guard let pendingPairingAction else { return }
        self.pendingPairingAction = nil
        switch pendingPairingAction {
        case .apply(let sourcePageIndex, let revisedPageIndex):
            applyManualPairing(
                sourcePageIndex: sourcePageIndex,
                revisedPageIndex: revisedPageIndex
            )
        case .reset(let sourcePageIndex):
            removeManualPairing(sourcePageIndex: sourcePageIndex)
        }
    }

    private func allowedRevisedRange(
        for sourcePageIndex: Int
    ) -> ClosedRange<Int>? {
        var previousRevisedPage: Int?
        var nextRevisedPage: Int?
        for match in review.resolvedManualPageMatches {
            if match.sourcePageIndex < sourcePageIndex {
                previousRevisedPage = max(
                    previousRevisedPage ?? match.revisedPageIndex,
                    match.revisedPageIndex
                )
            } else if match.sourcePageIndex > sourcePageIndex {
                nextRevisedPage = min(
                    nextRevisedPage ?? match.revisedPageIndex,
                    match.revisedPageIndex
                )
            }
        }
        let lowerBound = previousRevisedPage.map { $0 + 1 } ?? 0
        let upperBound = nextRevisedPage.map { $0 - 1 }
            ?? max(0, review.revisedPageCount - 1)
        guard lowerBound <= upperBound,
              lowerBound >= 0,
              upperBound < review.revisedPageCount
        else { return nil }
        return lowerBound...upperBound
    }

    private func applyManualPairing(
        sourcePageIndex: Int,
        revisedPageIndex: Int
    ) {
        var matches = review.resolvedManualPageMatches.filter {
            $0.sourcePageIndex != sourcePageIndex
                && $0.revisedPageIndex != revisedPageIndex
        }
        matches.append(
            PDFManualPageMatch(
                sourcePageIndex: sourcePageIndex,
                revisedPageIndex: revisedPageIndex
            )
        )
        matches.sort {
            $0.sourcePageIndex < $1.sourcePageIndex
        }
        recomputePairing(
            manualMatches: matches,
            sourcePageIndex: sourcePageIndex,
            revisedPageIndex: revisedPageIndex
        )
    }

    private func removeManualPairing(
        sourcePageIndex: Int
    ) {
        let matches = review.resolvedManualPageMatches.filter {
            $0.sourcePageIndex != sourcePageIndex
        }
        recomputePairing(
            manualMatches: matches,
            sourcePageIndex: sourcePageIndex,
            revisedPageIndex: currentPage
        )
    }

    private func recomputePairing(
        manualMatches: [PDFManualPageMatch],
        sourcePageIndex: Int,
        revisedPageIndex: Int
    ) {
        let request = PairingRequest(
            manualMatches: manualMatches,
            sourcePageIndex: sourcePageIndex,
            revisedPageIndex: revisedPageIndex
        )
        guard scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else {
            failedPairingRequest = request
            pairingError =
                "Comparison stopped. Start again when PaperPath is active."
            pairingErrorFeedback += 1
            return
        }
        pairingEditor = nil
        pairingGeneration = UUID()
        let generation = pairingGeneration
        pairingTask?.cancel()
        activePairingRequest = request
        failedPairingRequest = nil
        pairingError = nil
        isRecomputingPairing = true
        pairingProgress = .starting
        pairingTask = Task { @MainActor in
            do {
                let updated = try await configuration.recompute(
                    request.manualMatches
                ) { update in
                    guard pairingGeneration == generation,
                          update.fractionCompleted
                            >= pairingProgress.fractionCompleted
                    else { return }
                    pairingProgress = update
                }
                try Task.checkCancellation()
                guard pairingGeneration == generation else {
                    return
                }
                review = updated
                pageMatchLookup = PDFPageMatchLookup(review: updated)
                rebuildChangeIndexSnapshot()
                onReviewUpdated(updated)
                activePairingRequest = nil
                failedPairingRequest = nil
                isRecomputingPairing = false
                pairingTask = nil
                pairingProgress = .starting
                historicalPage = min(
                    max(request.sourcePageIndex, 0),
                    max(configuration.sourcePageCount - 1, 0)
                )
                currentPage = min(
                    max(request.revisedPageIndex, 0),
                    max(updated.revisedPageCount - 1, 0)
                )
                historicalNavigationToken &+= 1
                currentNavigationToken &+= 1
                if let index = updated.changes.firstIndex(
                    where: {
                        $0.resolvedSourcePageIndex
                            == request.sourcePageIndex
                            && $0.resolvedRevisedPageIndex
                                == request.revisedPageIndex
                    }
                ) {
                    selectedChangeIndex = index
                    open(updated.changes[index])
                } else {
                    selectedChangeIndex = min(
                        selectedChangeIndex,
                        max(updated.changes.count - 1, 0)
                    )
                }
                normalizeChangeSelection()
                pairingSuccessFeedback += 1
            } catch is CancellationError {
                guard pairingGeneration == generation else {
                    return
                }
                activePairingRequest = nil
                isRecomputingPairing = false
                pairingTask = nil
                pairingProgress = .starting
            } catch {
                guard pairingGeneration == generation else {
                    return
                }
                activePairingRequest = nil
                failedPairingRequest = request
                isRecomputingPairing = false
                pairingTask = nil
                pairingProgress = .starting
                pairingError = AppLocalization
                    .userFacingErrorDescription(error)
                pairingErrorFeedback += 1
            }
        }
    }

    private func retryFailedPairing() {
        guard let request = failedPairingRequest else { return }
        recomputePairing(
            manualMatches: request.manualMatches,
            sourcePageIndex: request.sourcePageIndex,
            revisedPageIndex: request.revisedPageIndex
        )
    }

    private func stopPairingRecomputation(
        offersRetry: Bool = true
    ) {
        let interruptedRequest = activePairingRequest
        pairingGeneration = UUID()
        pairingTask?.cancel()
        pairingTask = nil
        activePairingRequest = nil
        pairingProgress = .starting
        isRecomputingPairing = false
        if offersRetry, let interruptedRequest {
            failedPairingRequest = interruptedRequest
            pairingError =
                "Comparison stopped. Retry when you are ready."
        }
    }

    private func interruptProtectedProof() {
        isConfirmingAutomaticPairing = false
        pairingEditor = nil
        pendingPairingAction = nil
        presentedTextEvidence = nil
        presentedVectorEvidence = nil
        guard isRecomputingPairing else { return }
        stopPairingRecomputation()
        pairingError =
            "Comparison stopped. Start again when PaperPath is active."
        pairingErrorFeedback += 1
    }

    private func restoreState() {
        if savedSnapshotID == configuration.id {
            historicalPage = min(
                max(savedHistoricalPage, 0),
                max(configuration.sourcePageCount - 1, 0)
            )
            currentPage = min(
                max(savedCurrentPage, 0),
                max(review.revisedPageCount - 1, 0)
            )
            selectedChangeIndex = min(
                max(savedChangeIndex, 0),
                max(review.changes.count - 1, 0)
            )
        } else if configuration.initialSourcePageIndex != nil
                    || configuration.initialRevisedPageIndex != nil
                    || configuration.initialChangeIndex != nil {
            historicalPage = min(
                max(configuration.initialSourcePageIndex ?? 0, 0),
                max(configuration.sourcePageCount - 1, 0)
            )
            currentPage = min(
                max(configuration.initialRevisedPageIndex ?? 0, 0),
                max(review.revisedPageCount - 1, 0)
            )
            selectedChangeIndex = min(
                max(configuration.initialChangeIndex ?? 0, 0),
                max(review.changes.count - 1, 0)
            )
        } else if let first = review.changes.first {
            open(first)
        }
        savedSnapshotID = configuration.id
        historicalNavigationToken &+= 1
        currentNavigationToken &+= 1
    }

    private func normalizeChangeSelection() {
        if ChangeFilter(rawValue: savedChangeFilter) == nil {
            savedChangeFilter = ChangeFilter.all.rawValue
        }
        var visibleIndices = filteredChangeIndices
        if visibleIndices.isEmpty,
           !review.changes.isEmpty,
           selectedChangeFilter != .all {
            savedChangeFilter = ChangeFilter.all.rawValue
            visibleIndices = filteredChangeIndices
        }
        guard let first = visibleIndices.first else {
            selectedChangeIndex = 0
            return
        }
        guard filteredPosition(of: selectedChangeIndex) == nil else {
            return
        }
        selectedChangeIndex = first
        open(review.changes[first])
    }

    private func rebuildChangeIndexSnapshot() {
        changeIndexSnapshot = ChangeIndexSnapshot.build(
            for: review
        )
        rebuildFilteredChangeIndices()
    }

    private func rebuildFilteredChangeIndices() {
        let filter = selectedChangeFilter
        filteredChangeIndices = review.changes.indices.filter {
            filter.includes(review.changes[$0])
        }
    }

    private func scrollToSelectedChange(
        using proxy: ScrollViewProxy
    ) {
        guard review.changes.indices.contains(selectedChangeIndex),
              selectedChangeFilter.includes(
                  review.changes[selectedChangeIndex]
              )
        else {
            return
        }
        if reduceMotion {
            proxy.scrollTo(selectedChangeIndex, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(selectedChangeIndex, anchor: .center)
            }
        }
    }

    private func historicalPageChanged(_ page: Int) {
        guard historicalPage != page else { return }
        historicalPage = page
        guard syncPages,
              let peer = pageMatchLookup.revisedPage(
                matchingSourcePage: page
              )
        else { return }
        currentPage = peer
        currentNavigationToken &+= 1
    }

    private func currentPageChanged(_ page: Int) {
        guard currentPage != page else { return }
        currentPage = page
        guard syncPages,
              let peer = pageMatchLookup.sourcePage(
                matchingRevisedPage: page
              )
        else { return }
        historicalPage = peer
        historicalNavigationToken &+= 1
    }

    private func moveChange(_ offset: Int) {
        let visibleIndices = filteredChangeIndices
        guard !visibleIndices.isEmpty else { return }
        let currentPosition =
            filteredPosition(of: selectedChangeIndex) ?? 0
        let nextPosition = (
            currentPosition + offset + visibleIndices.count
        ) % visibleIndices.count
        selectedChangeIndex = visibleIndices[nextPosition]
        open(review.changes[selectedChangeIndex])
    }

    private func filteredPosition(of target: Int) -> Int? {
        var lowerBound = 0
        var upperBound = filteredChangeIndices.count
        while lowerBound < upperBound {
            let middle = lowerBound
                + (upperBound - lowerBound) / 2
            let value = filteredChangeIndices[middle]
            if value < target {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound < filteredChangeIndices.count,
              filteredChangeIndices[lowerBound] == target
        else { return nil }
        return lowerBound
    }

    private func open(_ change: PDFPageChange) {
        if usesCompactProofLayout {
            if change.resolvedSourcePageIndex == nil {
                selectedProofSide = .current
            } else if change.resolvedRevisedPageIndex == nil {
                selectedProofSide = .saved
            }
        }
        if let source = change.resolvedSourcePageIndex {
            historicalPage = source
            historicalNavigationToken &+= 1
        }
        if let revised = change.resolvedRevisedPageIndex {
            currentPage = revised
            currentNavigationToken &+= 1
        }
    }

    private func pagePair(_ change: PDFPageChange) -> String {
        let saved = change.resolvedSourcePageIndex.map {
            "S\($0 + 1)"
        } ?? "S—"
        let current = change.resolvedRevisedPageIndex.map {
            "C\($0 + 1)"
        } ?? "C—"
        return "\(saved) → \(current)"
    }

    private func revisionMetric(
        value: String,
        label: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
            Text(label.localizedUI)
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
        }
    }
}

private struct PDFTextEvidenceDetailView: View {
    private enum CopyStatus: Equatable {
        case idle
        case copied
        case failed
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let change: PDFPageChange
    let sourceLabel: String
    let revisedLabel: String

    @State private var copyStatus = CopyStatus.idle
    @State private var copySuccessFeedback = 0
    @State private var copyErrorFeedback = 0
    @State private var copyExpirationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.large
                ) {
                    evidenceHeader
                    evidenceSection(
                        title: "REMOVED TEXT",
                        sideLabel: sourceLabel,
                        evidence: change.sourceTextDifferences ?? [],
                        omittedCount:
                            change
                                .resolvedSourceTextDifferenceOmittedCount,
                        tint: PPColor.rose,
                        symbol: "text.badge.minus"
                    )
                    evidenceSection(
                        title: "INSERTED TEXT",
                        sideLabel: revisedLabel,
                        evidence: change.revisedTextDifferences ?? [],
                        omittedCount:
                            change
                                .resolvedRevisedTextDifferenceOmittedCount,
                        tint: PPColor.mint,
                        symbol: "text.badge.plus"
                    )
                    scopeNotice
                }
                .frame(maxWidth: 720)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background(PPCanvas())
            .navigationTitle("Text Change Evidence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyAllEvidence()
                    } label: {
                        Image(
                            systemName: copyStatus == .copied
                                ? "checkmark"
                                : "doc.on.doc"
                        )
                    }
                    .disabled(copyPayload.isEmpty)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(copyAccessibilityLabel)
                    .accessibilityHint(
                        (
                            copyStatus == .copied
                                ? "Copies again and restarts the five-minute expiry."
                                : "Copies retained evidence locally for five minutes."
                        ).localizedUI
                    )
                }
            }
            .sensoryFeedback(
                .success,
                trigger: copySuccessFeedback
            )
            .sensoryFeedback(
                .error,
                trigger: copyErrorFeedback
            )
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                dismissProtectedEvidence()
            } else if phase == .active,
                      copyStatus == .copied,
                      !SecurePasteboard.isOwnedContentCurrent {
                resetCopyStatus()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            dismissProtectedEvidence()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIPasteboard.changedNotification
            )
        ) { _ in
            guard copyStatus == .copied,
                  !SecurePasteboard.isOwnedContentCurrent
            else { return }
            resetCopyStatus()
        }
        .onDisappear {
            copyExpirationTask?.cancel()
            copyExpirationTask = nil
        }
        .accessibilityAction(.escape) {
            dismissProtectedEvidence()
        }
    }

    private var evidenceHeader: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "BOUNDED LOCAL EVIDENCE")
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
            layout {
                ToolSymbolPlate(
                    symbol: change.hasCharacterDifferences
                        ? "textformat"
                        : "text.quote",
                    tint: change.hasCharacterDifferences
                        ? PPColor.amber
                        : PPColor.accent,
                    size: 44
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(pagePairLabel)
                        .font(.title3.bold())
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(change.localizedTextEvidenceCountLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    copyStatusLabel
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var copyStatusLabel: some View {
        switch copyStatus {
        case .idle:
            EmptyView()
        case .copied:
            Label(
                "Copied locally for five minutes".localizedUI,
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(PPColor.mint)
        case .failed:
            Label(
                "This evidence is too large to copy at once".localizedUI,
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(PPColor.rose)
        }
    }

    private func evidenceSection(
        title: String,
        sideLabel: String,
        evidence: [PDFTextDifferenceEvidence],
        omittedCount: Int,
        tint: Color,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioSectionRule(
                title: title,
                detail: sideLabel.localizedUI,
                symbol: symbol,
                count: evidence.count,
                tint: tint
            )
            .padding(.bottom, PPSpacing.xSmall)

            if evidence.isEmpty {
                Text("No retained text marks on this side".localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .padding(.vertical, PPSpacing.medium)
            } else {
                ForEach(
                    Array(evidence.enumerated()),
                    id: \.offset
                ) { index, item in
                    evidenceRow(
                        item,
                        index: index,
                        tint: tint
                    )
                }
            }

            if omittedCount > 0 {
                Label(
                    AppLocalization.format(
                        "%lld additional text marks not retained",
                        omittedCount
                    ),
                    systemImage: "ellipsis.rectangle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .padding(.top, PPSpacing.small)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func evidenceRow(
        _ item: PDFTextDifferenceEvidence,
        index: Int,
        tint: Color
    ) -> some View {
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
                    spacing: PPSpacing.medium
                )
            )
        return layout {
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        evidenceGranularity(item, tint: tint)
                        evidenceRegion(item)
                    }
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xSmall
                    ) {
                        evidenceGranularity(item, tint: tint)
                        evidenceRegion(item)
                    }
                }
                Text(verbatim: displayText(item.text))
                    .font(.body)
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.56))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .combine)
    }

    private func evidenceGranularity(
        _ item: PDFTextDifferenceEvidence,
        tint: Color
    ) -> some View {
        Text(item.resolvedGranularity.title.localizedUI)
            .font(.caption2.smallCaps().weight(.bold))
            .foregroundStyle(tint)
    }

    private func evidenceRegion(
        _ item: PDFTextDifferenceEvidence
    ) -> some View {
        Text(regionLabel(item.region))
            .font(.caption2.monospaced())
            .foregroundStyle(PPColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var scopeNotice: some View {
        Label(
            "Comparison evidence is bounded; omitted counts are disclosed separately."
                .localizedUI,
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(PPColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pagePairLabel: String {
        let sourcePage = change.resolvedSourcePageIndex.map {
            AppLocalization.format(
                "%@ page %lld",
                sourceLabel.localizedUI,
                $0 + 1
            )
        } ?? AppLocalization.format(
            "%@ page missing",
            sourceLabel.localizedUI
        )
        let revisedPage = change.resolvedRevisedPageIndex.map {
            AppLocalization.format(
                "%@ page %lld",
                revisedLabel.localizedUI,
                $0 + 1
            )
        } ?? AppLocalization.format(
            "%@ page missing",
            revisedLabel.localizedUI
        )
        return "\(sourcePage) \u{2192} \(revisedPage)"
    }

    private var copyAccessibilityLabel: String {
        switch copyStatus {
        case .idle, .failed:
            return "Copy all text evidence".localizedUI
        case .copied:
            return "Copy text evidence again".localizedUI
        }
    }

    private var copyPayload: String {
        var lines = [
            "PaperPath Text Change Evidence".localizedUI,
            pagePairLabel,
            change.localizedTextEvidenceCountLabel,
            "",
            AppLocalization.format(
                "%@ - %@",
                sourceLabel.localizedUI,
                "Removed".localizedUI
            )
        ]
        appendEvidence(
            change.sourceTextDifferences ?? [],
            omittedCount:
                change.resolvedSourceTextDifferenceOmittedCount,
            to: &lines
        )
        lines.append("")
        lines.append(
            AppLocalization.format(
                "%@ - %@",
                revisedLabel.localizedUI,
                "Inserted".localizedUI
            )
        )
        appendEvidence(
            change.revisedTextDifferences ?? [],
            omittedCount:
                change.resolvedRevisedTextDifferenceOmittedCount,
            to: &lines
        )
        return lines.joined(separator: "\n")
    }

    private func appendEvidence(
        _ evidence: [PDFTextDifferenceEvidence],
        omittedCount: Int,
        to lines: inout [String]
    ) {
        for (index, item) in evidence.enumerated() {
            lines.append(
                "\(index + 1). [\(item.resolvedGranularity.title.localizedUI)] \(item.text)"
            )
        }
        if omittedCount > 0 {
            lines.append(
                AppLocalization.format(
                    "%lld additional text marks not retained",
                    omittedCount
                )
            )
        }
    }

    private func copyAllEvidence() {
        if SecurePasteboard.copy(copyPayload) {
            copyStatus = .copied
            copySuccessFeedback += 1
            scheduleCopyStatusExpiration()
        } else {
            copyExpirationTask?.cancel()
            copyExpirationTask = nil
            copyStatus = .failed
            copyErrorFeedback += 1
        }
    }

    private func scheduleCopyStatusExpiration() {
        copyExpirationTask?.cancel()
        copyExpirationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5 * 60))
            guard !Task.isCancelled else { return }
            copyStatus = .idle
            copyExpirationTask = nil
        }
    }

    private func resetCopyStatus() {
        copyExpirationTask?.cancel()
        copyExpirationTask = nil
        copyStatus = .idle
    }

    private func displayText(_ value: String) -> String {
        guard !value.isEmpty,
              value.allSatisfy(\.isWhitespace)
        else { return value }
        return value.map { character in
            switch character {
            case " ": return "\u{2420}"
            case "\n", "\r": return "\u{21B5}"
            case "\t": return "\u{21E5}"
            default: return String(character)
            }
        }
        .joined()
    }

    private func regionLabel(
        _ region: PDFDifferenceRegion
    ) -> String {
        String(
            format: "x %.3f  y %.3f  w %.3f  h %.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            region.x,
            region.y,
            region.width,
            region.height
        )
    }

    private func dismissProtectedEvidence() {
        resetCopyStatus()
        dismiss()
    }
}

private struct PDFVectorEvidenceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let change: PDFPageChange
    let sourceLabel: String
    let revisedLabel: String
    let isLayerVisible: Bool
    let onReveal: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.large
                ) {
                    evidenceHeader
                    evidenceSection(
                        title: "REMOVED VECTOR BOUNDS",
                        sideLabel: sourceLabel,
                        evidence:
                            change.sourceVectorDifferences ?? [],
                        tint: PPColor.cyan
                    )
                    evidenceSection(
                        title: "ADDED VECTOR BOUNDS",
                        sideLabel: revisedLabel,
                        evidence:
                            change.revisedVectorDifferences ?? [],
                        tint: PPColor.amber
                    )
                    scopeNotice
                }
                .frame(maxWidth: 720)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background(PPCanvas())
            .navigationTitle("Vector Change Evidence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    onReveal()
                    dismiss()
                } label: {
                    Label(
                        isLayerVisible
                            ? "Return to Proof"
                            : "Show Bounds in Proof",
                        systemImage: "square.dashed"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(
                    (
                        isLayerVisible
                            ? "Returns to the page with vector boundaries visible."
                            : "Enables vector boundaries and returns to the page."
                    ).localizedUI
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
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            dismiss()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            dismiss()
        }
        .accessibilityAction(.escape) {
            dismiss()
        }
    }

    private var evidenceHeader: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "BOUNDED LOCAL EVIDENCE")
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
            layout {
                ToolSymbolPlate(
                    symbol: "square.dashed",
                    tint: PPColor.cyan,
                    size: 44
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(pagePairLabel)
                        .font(.title3.bold())
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(change.localizedVectorEvidenceCountLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func evidenceSection(
        title: String,
        sideLabel: String,
        evidence: [PDFVectorDifferenceEvidence],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioSectionRule(
                title: title,
                detail: sideLabel.localizedUI,
                symbol: "square.dashed",
                count: evidence.count,
                tint: tint
            )
            .padding(.bottom, PPSpacing.xSmall)

            if evidence.isEmpty {
                Text(
                    "No retained vector boundaries on this side"
                        .localizedUI
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .padding(.vertical, PPSpacing.medium)
            } else {
                ForEach(
                    Array(evidence.enumerated()),
                    id: \.offset
                ) { index, item in
                    evidenceRow(
                        item,
                        index: index,
                        tint: tint
                    )
                }
            }
        }
    }

    private func evidenceRow(
        _ item: PDFVectorDifferenceEvidence,
        index: Int,
        tint: Color
    ) -> some View {
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
                    spacing: PPSpacing.medium
                )
            )

        return layout {
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.kind.title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(locationDescription(item.region))
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(areaDescription(item.region))
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                Text(normalizedBounds(item.region))
                    .font(.caption2.monospaced())
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.56))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [
                item.kind.title.localizedUI,
                locationDescription(item.region),
                areaDescription(item.region)
            ].joined(separator: " · ")
        )
    }

    private var scopeNotice: some View {
        Label(
            "Vector bounds show changed drawings, not their type or meaning."
                .localizedUI,
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(PPColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pagePairLabel: String {
        let sourcePage = change.resolvedSourcePageIndex.map {
            AppLocalization.format(
                "%@ page %lld",
                sourceLabel.localizedUI,
                $0 + 1
            )
        } ?? AppLocalization.format(
            "%@ page missing",
            sourceLabel.localizedUI
        )
        let revisedPage = change.resolvedRevisedPageIndex.map {
            AppLocalization.format(
                "%@ page %lld",
                revisedLabel.localizedUI,
                $0 + 1
            )
        } ?? AppLocalization.format(
            "%@ page missing",
            revisedLabel.localizedUI
        )
        return "\(sourcePage) \u{2192} \(revisedPage)"
    }

    private func locationDescription(
        _ region: PDFDifferenceRegion
    ) -> String {
        let centerX = min(1, max(0, region.x + region.width / 2))
        let centerY = min(1, max(0, region.y + region.height / 2))
        let horizontal: String
        if centerX < 1 / 3 {
            horizontal = "Left side"
        } else if centerX > 2 / 3 {
            horizontal = "Right side"
        } else {
            horizontal = "Horizontal center"
        }
        let vertical: String
        if centerY < 1 / 3 {
            vertical = "Top"
        } else if centerY > 2 / 3 {
            vertical = "Bottom"
        } else {
            vertical = "Vertical center"
        }
        if horizontal == "Horizontal center",
           vertical == "Vertical center" {
            return "Page center".localizedUI
        }
        return AppLocalization.format(
            "%@ · %@",
            vertical.localizedUI,
            horizontal.localizedUI
        )
    }

    private func areaDescription(
        _ region: PDFDifferenceRegion
    ) -> String {
        let area = min(
            1,
            max(0, region.width) * max(0, region.height)
        )
        let percentage = area * 100
        if percentage > 0, percentage < 1 {
            return "<1% of page area".localizedUI
        }
        return AppLocalization.format(
            "%lld%% of page area",
            Int(percentage.rounded())
        )
    }

    private func normalizedBounds(
        _ region: PDFDifferenceRegion
    ) -> String {
        let coordinates = String(
            format: "x %.3f  y %.3f  w %.3f  h %.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            region.x,
            region.y,
            region.width,
            region.height
        )
        return AppLocalization.format(
            "Normalized bounds · %@",
            coordinates
        )
    }
}
