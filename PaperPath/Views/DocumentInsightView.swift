import SwiftUI

struct DocumentInsightView: View {
    @Environment(\.dismiss) private var dismiss
    let record: DocumentRecord

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                ScrollView {
                    VStack(alignment: .leading, spacing: PPSpacing.large) {
                        summary
                        metrics
                        recommendations
                        privacy
                    }
                    .frame(maxWidth: 880)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Document insight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var summary: some View {
        WorkflowCommandHeader(
            eyebrow: "DOCUMENT EVIDENCE",
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
                    value: "\(Int(record.profile.textCoverage * 100))%",
                    label: "Text",
                    symbol: "textformat",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "\(record.profile.recommendedActions.count)",
                    label: "Next steps",
                    symbol: "checklist",
                    tint: PPColor.amber
                )
            ]
        )
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "WHAT PAPERPATH FOUND")
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: PPSpacing.medium),
                    GridItem(.flexible(), spacing: PPSpacing.medium)
                ],
                spacing: PPSpacing.medium
            ) {
                ProfileMetric(
                    value: "\(record.profile.pageCount)",
                    label: "Pages",
                    symbol: "doc.on.doc"
                )
                ProfileMetric(
                    value: record.profile.formattedSize,
                    label: "Private copy",
                    symbol: "internaldrive"
                )
                ProfileMetric(
                    value: "\(Int(record.profile.textCoverage * 100))%",
                    label: "Text coverage",
                    symbol: "textformat"
                )
                ProfileMetric(
                    value: "\(record.profile.formFieldCount)",
                    label: "Form fields",
                    symbol: "list.bullet.clipboard"
                )
            }
        }
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "SHORTEST USEFUL PATH")
            VStack(spacing: 0) {
                ForEach(
                    Array(record.profile.recommendedActions.enumerated()),
                    id: \.element.id
                ) { index, action in
                    HStack(alignment: .top, spacing: PPSpacing.medium) {
                        Image(systemName: action.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(PPColor.accent)
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
                    }
                    .padding(.vertical, PPSpacing.medium)

                    if index < record.profile.recommendedActions.count - 1 {
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
            SectionEyebrow(text: "PRIVACY EVIDENCE")
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
        HStack {
            Label(title.localizedUI, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(PPColor.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PDFTechnicalInspectorView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let recordID: UUID
    let unlockPassword: String?

    @State private var inspection: PDFTechnicalInspection?
    @State private var isLoading = true
    @State private var loadGeneration = 0

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
                                ContentUnavailableView(
                                    "Inspection unavailable",
                                    systemImage: "doc.badge.ellipsis",
                                    description: Text(
                                        "The private working copy could not be inspected."
                                    )
                                )
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
                    Button("Done") { dismiss() }
                }
            }
            .task(id: model.refreshToken(for: recordID)) {
                await reload()
            }
        }
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
           !dynamicTypeSize.isAccessibilitySize {
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
                columns: [
                    GridItem(.flexible(), spacing: PPSpacing.medium),
                    GridItem(.flexible(), spacing: PPSpacing.medium)
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
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(2)
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
        HStack(alignment: .firstTextBaseline, spacing: PPSpacing.medium) {
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
        let review: PDFChangeReview

        var id: UUID { version.id }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recordID: UUID
    let initialVersionID: UUID?
    let onOpenPage: ((UUID, Int) -> Void)?

    @State private var versions: [PDFVersionSnapshot] = []
    @State private var selectedVersion: PDFVersionSnapshot?
    @State private var inspectedVersion: PDFVersionSnapshot?
    @State private var inspectedVersionURL: URL?
    @State private var comparisonReview: PDFChangeReview?
    @State private var isLoading = true
    @State private var isRestoring = false
    @State private var isComparing = false
    @State private var loadGeneration = 0
    @State private var restoreTask: Task<Void, Never>?
    @State private var comparisonTask: Task<Void, Never>?
    @State private var revisionProof: RevisionProofPayload?
    @State private var editingMilestone: PDFVersionSnapshot?
    @State private var linkedReceiptVersion: PDFVersionSnapshot?
    @State private var appliedInitialVersion = false
    @State private var pinnedStorageSummary =
        PDFPinnedVersionStorageSummary.empty
    @State private var versionArchiveURL: URL?
    @State private var isSharingVersionArchive = false
    @State private var isCreatingVersionArchive = false
    @State private var versionArchiveTask: Task<Void, Never>?

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
                            currentSummary(record)
                            if let inspectedVersion {
                                revisionBench(
                                    inspectedVersion,
                                    current: record
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
                if isLoading || isRestoring || isComparing {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            (
                                isRestoring
                                    ? "Restoring version"
                                    : isComparing
                                        ? "Comparing revision"
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
                    Button((isRestoring ? "Stop" : "Done").localizedUI) {
                        if isRestoring {
                            restoreTask?.cancel()
                            restoreTask = nil
                            isRestoring = false
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
                    "Your current working copy will be saved first. The Files original stays untouched."
                )
            }
            .interactiveDismissDisabled(isRestoring)
            .fullScreenCover(item: $revisionProof) { payload in
                PDFHistoricalRevisionProofView(
                    recordID: recordID,
                    version: payload.version,
                    historicalURL: payload.historicalURL,
                    review: payload.review
                )
            }
            .sheet(item: $editingMilestone) { version in
                PDFVersionMilestoneEditor(
                    recordID: recordID,
                    version: version
                ) { updated in
                    versions = updated
                    Task {
                        await refreshPinnedStorageSummary()
                    }
                    if inspectedVersion?.id == version.id {
                        inspectedVersion = updated.first {
                            $0.id == version.id
                        }
                    }
                }
                .presentationDetents(
                    dynamicTypeSize.isAccessibilitySize
                        ? [.large]
                        : [.medium, .large]
                )
            }
            .sheet(item: $linkedReceiptVersion) { _ in
                DeliveryReceiptView(recordID: recordID) {
                    targetRecordID,
                    pageIndex in
                    linkedReceiptVersion = nil
                    onOpenPage?(targetRecordID, pageIndex)
                }
            }
            .sheet(isPresented: $isSharingVersionArchive) {
                if let versionArchiveURL {
                    ShareSheet(items: [versionArchiveURL])
                }
            }
            .onDisappear {
                versionArchiveTask?.cancel()
                versionArchiveTask = nil
                restoreTask?.cancel()
                restoreTask = nil
                comparisonTask?.cancel()
                comparisonTask = nil
                if let versionArchiveURL {
                    try? FileManager.default.removeItem(
                        at: versionArchiveURL
                            .deletingLastPathComponent()
                    )
                    self.versionArchiveURL = nil
                }
            }
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
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "CURRENT VERSION")
            HStack(spacing: PPSpacing.large) {
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
                Spacer(minLength: PPSpacing.medium)
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

            HStack(spacing: PPSpacing.large) {
                policyValue(
                    value: "12",
                    label: "Rotating"
                )
                policyValue(
                    value: "\(pinnedVersionCount)",
                    label: "Milestones"
                )
                policyValue(
                    value: pinnedStorageSummary.formattedBytes,
                    label: "Pinned storage"
                )
            }

            if pinnedStorageSummary.isNearCapacity {
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(PPColor.amber)
                    Text(
                        "Pinned milestones are nearing the 1 GB library budget."
                            .localizedUI
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    Spacer(minLength: 0)
                    Text(pinnedStorageSummary.countContract)
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(PPColor.amber)
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
                    createVersionArchive()
                } label: {
                    Label(
                        isCreatingVersionArchive
                            ? "Archiving milestones"
                            : "Export Milestone Archive",
                        systemImage: isCreatingVersionArchive
                            ? "hourglass"
                            : "archivebox"
                    )
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
                .disabled(isCreatingVersionArchive)
            }
        }
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
                            version.displayTitle.localizedUI
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
                HStack(spacing: PPSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Comparing saved and current revisions".localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                }
            }

            HStack(spacing: PPSpacing.medium) {
                if let inspectedVersionURL,
                   let comparisonReview {
                    Button {
                        revisionProof = RevisionProofPayload(
                            version: version,
                            historicalURL: inspectedVersionURL,
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
                    .disabled(isComparing || isRestoring)
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
                .disabled(isComparing || isRestoring)

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
                .disabled(isComparing || isRestoring)

                Button {
                    selectedVersion = version
                } label: {
                    Label(
                        "Restore This Revision",
                        systemImage: "arrow.uturn.backward"
                    )
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(isComparing || isRestoring)
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
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
                ProgressView()
                    .frame(width: 66, height: 84)
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

            if versions.isEmpty && !isLoading {
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
                Text(version.displayTitle.localizedUI)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(2)

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
                    .lineLimit(2)

                Text(shortFingerprint(version.contentFingerprint))
                    .font(.caption2.monospaced())
                    .foregroundStyle(PPColor.textSecondary)

                HStack(spacing: PPSpacing.small) {
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
                .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCurrent(version, record: current) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("CURRENT COPY".localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(PPColor.mint)
                    Button {
                        editingMilestone = version
                    } label: {
                        Image(
                            systemName: version.isPinnedMilestone
                                ? "pin.fill"
                                : "pin"
                        )
                        .frame(width: 38, height: 38)
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
                }
                .padding(.top, 2)
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
                    .frame(width: 38, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    version.isPinnedMilestone
                        ? PPColor.mint
                        : PPColor.textSecondary
                )
                .disabled(isRestoring || isComparing)
                .accessibilityLabel(
                    (
                        version.isPinnedMilestone
                            ? "Edit milestone"
                            : "Save as milestone"
                    ).localizedUI
                )

                Button {
                    inspect(version)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.body)
                        .frame(width: 38, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.cyan)
                .disabled(isRestoring || isComparing)
                .accessibilityLabel(
                    "Compare this version with the working copy"
                        .localizedUI
                )

                Button {
                    selectedVersion = version
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.accent)
                .disabled(isRestoring)
                .accessibilityLabel(
                    "Restore version from \(version.createdAt.formatted())"
                )
                .help("Restore this version")
            }
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func linkedReceiptControl(
        _ version: PDFVersionSnapshot
    ) -> some View {
        if let receipt = model.record(id: recordID)?.deliveryReceipt,
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
                .accessibilityIdentifier(
                    "openMilestoneReceipt-\(version.id.uuidString)"
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
    }

    private var totalVersionSize: String {
        ByteCountFormatter.string(
            fromByteCount: versions.reduce(Int64(0)) {
                $0 + $1.byteCount
            },
            countStyle: .file
        )
    }

    private var pinnedVersionCount: Int {
        versions.filter(\.isPinnedMilestone).count
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
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        async let versionsTask = model.versionHistory(
            recordID: recordID
        )
        async let pinnedTask = model.pinnedVersionMilestones()
        let (loadedVersions, pinnedVersions) = await (
            versionsTask,
            pinnedTask
        )
        guard !Task.isCancelled,
              generation == loadGeneration
        else { return }
        versions = loadedVersions
        pinnedStorageSummary = PDFPinnedVersionStorageSummary(
            milestoneCount: pinnedVersions.count,
            byteCount: pinnedVersions.reduce(Int64(0)) {
                $0 + max(0, $1.byteCount)
            }
        )
        if let inspectedVersion,
           !loadedVersions.contains(where: {
               $0.id == inspectedVersion.id
           }) {
            self.inspectedVersion = nil
            inspectedVersionURL = nil
            comparisonReview = nil
        }
        isLoading = false
        if !appliedInitialVersion {
            appliedInitialVersion = true
            if let initialVersionID,
               let initial = loadedVersions.first(where: {
                   $0.id == initialVersionID
               }) {
                inspect(initial)
            }
        }
    }

    private func refreshPinnedStorageSummary() async {
        let pinnedVersions = await model.pinnedVersionMilestones()
        pinnedStorageSummary = PDFPinnedVersionStorageSummary(
            milestoneCount: pinnedVersions.count,
            byteCount: pinnedVersions.reduce(Int64(0)) {
                $0 + max(0, $1.byteCount)
            }
        )
    }

    private func createVersionArchive() {
        versionArchiveTask?.cancel()
        isCreatingVersionArchive = true
        versionArchiveTask = Task {
            let archive = await model.makePinnedVersionArchive(
                recordID: recordID
            )
            guard !Task.isCancelled else { return }
            isCreatingVersionArchive = false
            versionArchiveTask = nil
            guard let archive else { return }
            if let previous = versionArchiveURL {
                try? FileManager.default.removeItem(
                    at: previous.deletingLastPathComponent()
                )
            }
            versionArchiveURL = archive
            isSharingVersionArchive = true
        }
    }

    private func inspect(_ version: PDFVersionSnapshot) {
        comparisonTask?.cancel()
        inspectedVersion = version
        inspectedVersionURL = nil
        comparisonReview = nil
        isComparing = true
        comparisonTask = Task {
            async let loadedURL = model.versionFileURL(
                recordID: recordID,
                snapshotID: version.id
            )
            do {
                let review = try await model.compareVersion(
                    recordID: recordID,
                    snapshotID: version.id
                )
                let url = await loadedURL
                guard !Task.isCancelled,
                      inspectedVersion?.id == version.id
                else { return }
                inspectedVersionURL = url
                comparisonReview = review
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                model.present(error)
            }
            guard inspectedVersion?.id == version.id else {
                return
            }
            isComparing = false
            comparisonTask = nil
        }
    }

    private func restore(_ version: PDFVersionSnapshot) {
        selectedVersion = nil
        isRestoring = true
        restoreTask = Task {
            let succeeded = await model.restoreVersion(
                recordID: recordID,
                snapshotID: version.id
            )
            guard !Task.isCancelled else {
                isRestoring = false
                restoreTask = nil
                return
            }
            isRestoring = false
            restoreTask = nil
            if succeeded {
                dismiss()
            } else {
                await reload()
            }
        }
    }
}

private struct PDFVersionMilestoneEditor: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let version: PDFVersionSnapshot
    let onSave: ([PDFVersionSnapshot]) -> Void

    @State private var name: String
    @State private var isPinned: Bool
    @State private var linksDelivery: Bool
    @State private var isSaving = false

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
                        TextField(
                            "e.g. Signed contract",
                            text: $name
                        )
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                    }

                    Toggle(isOn: $isPinned) {
                        Label(
                            "Protect from automatic cleanup",
                            systemImage: "pin"
                        )
                    }
                    .tint(PPColor.mint)

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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PPSpacing.regular)
            }
            .accessibilityIdentifier("versionMilestoneEditor")
            .background(PPColor.canvas)
            .navigationTitle("Version milestone".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".localizedUI) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".localizedUI) {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
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

    private func save() {
        isSaving = true
        Task {
            let updated = await model.updateVersionMilestone(
                recordID: recordID,
                snapshotID: version.id,
                name: name,
                pinned: isPinned,
                linksCurrentDeliveryReceipt: linksDelivery
            )
            isSaving = false
            guard let updated else { return }
            onSave(updated)
            dismiss()
        }
    }
}

private struct PDFHistoricalRevisionProofView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("versionProof.snapshotID")
    private var savedSnapshotID = ""
    @AppStorage("versionProof.savedPage")
    private var savedHistoricalPage = 0
    @AppStorage("versionProof.currentPage")
    private var savedCurrentPage = 0
    @AppStorage("versionProof.changeIndex")
    private var savedChangeIndex = 0
    @AppStorage("versionProof.syncPages")
    private var syncPages = true
    @AppStorage("versionProof.evidence")
    private var showsEvidence = true

    let recordID: UUID
    let version: PDFVersionSnapshot
    let historicalURL: URL
    let review: PDFChangeReview

    @State private var historicalPage = 0
    @State private var currentPage = 0
    @State private var historicalNavigationToken = 0
    @State private var currentNavigationToken = 0
    @State private var selectedChangeIndex = 0

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                HStack(spacing: 0) {
                    revisionRail
                    Rectangle()
                        .fill(PPColor.border.opacity(0.68))
                        .frame(width: 1)
                    proofPane(
                        label: "SAVED",
                        title: milestoneTitle,
                        url: historicalURL,
                        page: historicalPage,
                        pageCount: version.pageCount,
                        refreshToken: 0,
                        navigationToken: historicalNavigationToken,
                        tone: .source
                    ) { page in
                        historicalPageChanged(page)
                    }
                    Rectangle()
                        .fill(PPColor.border.opacity(0.68))
                        .frame(width: 1)
                    proofPane(
                        label: "CURRENT",
                        title: model.record(id: recordID)?
                            .displayName ?? "Working copy",
                        url: model.url(for: recordID)
                            ?? historicalURL,
                        page: currentPage,
                        pageCount: model.record(id: recordID)?
                            .profile.pageCount
                            ?? review.revisedPageCount,
                        refreshToken: model.refreshToken(
                            for: recordID
                        ),
                        navigationToken: currentNavigationToken,
                        tone: .revised
                    ) { page in
                        currentPageChanged(page)
                    }
                }
            }
            .navigationTitle("Historical proof".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Toggle(isOn: $syncPages) {
                        Image(systemName: "link")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help("Pages move together")

                    Toggle(isOn: $showsEvidence) {
                        Image(
                            systemName: showsEvidence
                                ? "viewfinder.circle.fill"
                                : "viewfinder.circle"
                        )
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(
                        showsEvidence
                            ? "Hide page evidence"
                            : "Show page evidence"
                    )

                    Button("Done".localizedUI) {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                proofCommandBar
            }
        }
        .onAppear {
            restoreState()
        }
        .onChange(of: historicalPage) { _, page in
            savedSnapshotID = version.id.uuidString
            savedHistoricalPage = page
        }
        .onChange(of: currentPage) { _, page in
            savedSnapshotID = version.id.uuidString
            savedCurrentPage = page
        }
        .onChange(of: selectedChangeIndex) { _, index in
            savedSnapshotID = version.id.uuidString
            savedChangeIndex = index
        }
    }

    private var milestoneTitle: String {
        version.displayTitle
    }

    private var selectedChange: PDFPageChange? {
        guard review.changes.indices.contains(
            selectedChangeIndex
        ) else {
            return review.changes.first
        }
        return review.changes[selectedChangeIndex]
    }

    private var revisionRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("REVISION EVIDENCE")
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                Spacer(minLength: 0)
                Text("\(review.changes.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.rose)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(minHeight: 38)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(review.changes.enumerated()),
                        id: \.element.id
                    ) { index, change in
                        Button {
                            selectedChangeIndex = index
                            open(change)
                        } label: {
                            HStack(spacing: PPSpacing.small) {
                                Image(
                                    systemName: change.resolvedMatchKind
                                        == .inserted
                                        ? "plus.circle"
                                        : change.resolvedMatchKind
                                            == .removed
                                            ? "minus.circle"
                                            : "viewfinder.circle"
                                )
                                .foregroundStyle(
                                    change.severity == .critical
                                        ? PPColor.rose
                                        : PPColor.amber
                                )
                                VStack(
                                    alignment: .leading,
                                    spacing: 1
                                ) {
                                    Text(pagePair(change))
                                        .font(
                                            .caption
                                                .monospacedDigit()
                                                .weight(.semibold)
                                        )
                                        .foregroundStyle(
                                            PPColor.textPrimary
                                        )
                                    Text(
                                        revisionEvidenceDetail(change)
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(
                                        PPColor.textSecondary
                                    )
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, PPSpacing.small)
                            .frame(minHeight: 48)
                            .background(
                                index == selectedChangeIndex
                                    ? PPColor.amber.opacity(0.07)
                                    : Color.clear
                            )
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(
                                        index == selectedChangeIndex
                                            ? PPColor.amber
                                            : PPColor.border
                                    )
                                    .frame(
                                        width: index
                                            == selectedChangeIndex
                                            ? 2
                                            : 0.6
                                    )
                            }
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(
                                        PPColor.border.opacity(0.48)
                                    )
                                    .frame(height: 0.6)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 190)
        .background(PPColor.elevated.opacity(0.78))
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
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(page + 1) / \(max(pageCount, 1))")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(minHeight: 38)
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

    private var proofCommandBar: some View {
        HStack(spacing: PPSpacing.medium) {
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
                value: "\(review.textChanges.filter(\.hasLocatedTextDifferences).count)",
                label: "Text",
                tint: PPColor.accent
            )
            Spacer(minLength: 0)
            Text(
                review.changes.isEmpty
                    ? "No deterministic changes".localizedUI
                    : "\(min(selectedChangeIndex + 1, review.changes.count)) / \(review.changes.count)"
            )
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(PPColor.textSecondary)
            Button {
                moveChange(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(review.changes.isEmpty)
            Button {
                moveChange(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(review.changes.isEmpty)
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

    private func evidenceOverlay(
        tone: PDFEvidenceOverlayTone,
        page: Int
    ) -> PDFEvidenceOverlay? {
        guard showsEvidence,
              let selectedChange,
              !(selectedChange.differenceRegions ?? []).isEmpty
                || selectedChange.hasLocatedTextDifferences
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
        return PDFEvidenceOverlay(
            pageIndex: page,
            regions: selectedChange.differenceRegions ?? [],
            textRegions: textEvidence.filter {
                $0.resolvedGranularity == .word
            }.map(\.region),
            characterTextRegions: textEvidence.filter {
                $0.resolvedGranularity == .character
            }.map(\.region),
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
            parts.append(
                AppLocalization.format(
                    change.hasCharacterDifferences
                        ? "%lld character mark%@"
                        : "%lld word mark%@",
                    change.textDifferenceCount,
                    change.textDifferenceCount == 1 ? "" : "s"
                )
            )
        }
        if let matchBasis = change.matchBasis {
            parts.append(matchBasis.title.localizedUI)
        }
        return parts.joined(separator: " · ")
    }

    private func restoreState() {
        if savedSnapshotID == version.id.uuidString {
            historicalPage = min(
                max(savedHistoricalPage, 0),
                max(version.pageCount - 1, 0)
            )
            currentPage = min(
                max(savedCurrentPage, 0),
                max(review.revisedPageCount - 1, 0)
            )
            selectedChangeIndex = min(
                max(savedChangeIndex, 0),
                max(review.changes.count - 1, 0)
            )
        } else if let first = review.changes.first {
            open(first)
        }
        historicalNavigationToken &+= 1
        currentNavigationToken &+= 1
    }

    private func historicalPageChanged(_ page: Int) {
        guard historicalPage != page else { return }
        historicalPage = page
        guard syncPages,
              let peer = review.revisedPage(
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
              let peer = review.sourcePage(
                matchingRevisedPage: page
              )
        else { return }
        historicalPage = peer
        historicalNavigationToken &+= 1
    }

    private func moveChange(_ offset: Int) {
        guard !review.changes.isEmpty else { return }
        selectedChangeIndex = (
            selectedChangeIndex + offset + review.changes.count
        ) % review.changes.count
        open(review.changes[selectedChangeIndex])
    }

    private func open(_ change: PDFPageChange) {
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
