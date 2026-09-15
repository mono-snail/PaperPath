import SwiftUI

struct DeliveryReceiptBadge: View {
    let receipt: PDFDeliveryReceipt
    var isCurrent = true

    var body: some View {
        HStack(spacing: 6) {
            Image(
                systemName: isCurrent
                    ? (
                        receipt.hasWarnings
                            ? "checkmark.shield"
                            : "checkmark.seal.fill"
                    )
                    : "arrow.triangle.2.circlepath"
            )
            Text(
                isCurrent
                    ? (receipt.hasWarnings ? "CHECKED" : "VERIFIED")
                    : "CHANGED"
            )
                .font(.caption2.smallCaps().weight(.bold))
        }
        .foregroundStyle(
            !isCurrent || receipt.hasWarnings
                ? PPColor.amber
                : PPColor.mint
        )
        .padding(.horizontal, 9)
        .frame(minHeight: 30)
        .overlay {
            Capsule()
                .stroke(
                    (
                        !isCurrent || receipt.hasWarnings
                            ? PPColor.amber
                            : PPColor.mint
                    ).opacity(0.62),
                    lineWidth: 0.8
                )
        }
        .accessibilityLabel(
            !isCurrent
                ? "Output changed after verification"
                : (
                    receipt.hasWarnings
                        ? "Output checked with a warning"
                        : "Output verified"
                )
        )
    }
}

struct OutputHistoryBadge: View {
    let count: Int

    var body: some View {
        Label(
            AppLocalization.format(
                "%lld OUTPUT%@",
                count,
                count == 1 ? "" : "S"
            ),
            systemImage: "clock.badge.checkmark"
        )
        .font(.caption2.smallCaps().weight(.bold))
        .foregroundStyle(PPColor.mint)
        .padding(.horizontal, 9)
        .frame(minHeight: 30)
        .overlay {
            Capsule()
                .stroke(PPColor.mint.opacity(0.56), lineWidth: 0.8)
        }
        .accessibilityLabel(
            AppLocalization.format(
                "%lld saved outputs",
                count
            )
        )
    }
}

struct ReceivedPackageBadge: View {
    let provenance: PDFReceivedPackageProvenance
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(
                systemName: isCurrent
                    ? "tray.and.arrow.down.fill"
                    : "arrow.triangle.2.circlepath"
            )
            Text(isCurrent ? "RECEIVED VERIFIED" : "CHANGED")
                .font(.caption2.smallCaps().weight(.bold))
        }
        .foregroundStyle(isCurrent ? PPColor.cyan : PPColor.amber)
        .padding(.horizontal, 9)
        .frame(minHeight: 30)
        .overlay {
            Capsule()
                .stroke(
                    (isCurrent ? PPColor.cyan : PPColor.amber)
                        .opacity(0.62),
                    lineWidth: 0.8
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isCurrent
                ? "Imported from a verified delivery package"
                : "Received PDF changed after import"
        )
        .accessibilityValue(provenance.sourceTitle.localizedUI)
    }
}

private extension SecurePasteboardCopyController.Status {
    var fingerprintActionTitle: String {
        switch self {
        case .idle:
            return "Copy hash"
        case .copied:
            return "Copied"
        case .failed:
            return "Try copy again"
        }
    }

    var fingerprintActionSymbol: String {
        switch self {
        case .idle:
            return "doc.on.doc"
        case .copied:
            return "checkmark"
        case .failed:
            return "arrow.clockwise"
        }
    }

    var fingerprintTint: Color {
        switch self {
        case .idle:
            return PPColor.accent
        case .copied:
            return PPColor.mint
        case .failed:
            return PPColor.amber
        }
    }
}

private struct SecureFingerprintCopyStatusLabel: View {
    let status: SecurePasteboardCopyController.Status

    var body: some View {
        switch status {
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
                "Fingerprint could not be copied".localizedUI,
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(PPColor.amber)
        }
    }
}

struct ReceivedPackageProvenanceView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let recordID: UUID
    let onVerify: () -> Void

    @StateObject private var fingerprintCopy =
        SecurePasteboardCopyController()

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if let record = model.record(id: recordID),
                   let provenance =
                    record.receivedPackageProvenance {
                    provenanceContent(
                        provenance,
                        isCurrent:
                            record.hasCurrentReceivedPackageProvenance
                    )
                } else {
                    ContentUnavailableView(
                        "Received package unavailable",
                        systemImage: "shippingbox",
                        description: Text(
                            "The private copy no longer contains received package evidence."
                        )
                    )
                }
            }
            .navigationTitle("Received Package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onChange(of: displayedPackageFingerprint) { _, _ in
            fingerprintCopy.reset()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                fingerprintCopy.synchronizeOwnership()
            } else if phase == .background {
                fingerprintCopy.reset()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIPasteboard.changedNotification
            )
        ) { _ in
            fingerprintCopy.synchronizeOwnership()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            fingerprintCopy.reset()
        }
        .onDisappear {
            fingerprintCopy.reset()
        }
        .accessibilityAction(.escape) {
            fingerprintCopy.reset()
            dismiss()
        }
        .sensoryFeedback(
            .success,
            trigger: fingerprintCopy.successFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: fingerprintCopy.errorFeedback
        )
    }

    private var displayedPackageFingerprint: String? {
        model.record(id: recordID)?
            .receivedPackageProvenance?
            .artifactSHA256
    }

    private func provenanceContent(
        _ provenance: PDFReceivedPackageProvenance,
        isCurrent: Bool
    ) -> some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: PPSpacing.large
            ) {
                WorkflowCommandHeader(
                    eyebrow: "RECEIVED EVIDENCE",
                    title: isCurrent
                        ? "Exact received bytes"
                        : "Working copy changed",
                    detail: isCurrent
                        ? "The current PDF still matches the signed Receipt checked during import."
                        : "The current PDF no longer matches the bytes checked during import.",
                    symbol: isCurrent
                        ? "checkmark.shield.fill"
                        : "arrow.triangle.2.circlepath",
                    tint: isCurrent ? PPColor.cyan : PPColor.amber,
                    metrics: [
                        WorkflowMetric(
                            value: provenance.operation.title,
                            label: "Operation",
                            symbol: provenance.operation.symbol,
                            tint: PPColor.accent
                        ),
                        WorkflowMetric(
                            value: provenance.formattedArtifactSize,
                            label: "Received size",
                            symbol: "externaldrive",
                            tint: PPColor.cyan
                        ),
                        WorkflowMetric(
                            value: isCurrent ? "Exact" : "Changed",
                            label: "Current bytes",
                            symbol: isCurrent
                                ? "equal.circle"
                                : "arrow.triangle.2.circlepath",
                            tint: isCurrent
                                ? PPColor.mint
                                : PPColor.amber
                        )
                    ]
                )

                evidenceSection(
                    eyebrow: "SIGNED SOURCE",
                    title: provenance.sourceTitle,
                    rows: [
                        EvidenceRow(
                            label: "Signer",
                            value: provenance.sourceTitle,
                            symbol: provenance.signerTrustStatus.symbol,
                            tint: signerTint(provenance.signerTrustStatus)
                        ),
                        EvidenceRow(
                            label: "Signer Key ID",
                            value: provenance.signerKeyID
                                ?? "Not available",
                            symbol: "key.horizontal",
                            tint: PPColor.textSecondary
                        ),
                        EvidenceRow(
                            label: "Package ID",
                            value: provenance.packageID.uuidString
                                .uppercased(),
                            symbol: "shippingbox",
                            tint: PPColor.cyan
                        ),
                        EvidenceRow(
                            label: "Receipt ID",
                            value: provenance.deliveryReceiptID
                                .uuidString.uppercased(),
                            symbol: "checkmark.seal",
                            tint: PPColor.mint
                        )
                    ]
                )

                evidenceSection(
                    eyebrow: "LOCAL TIMELINE",
                    title: "Verification history",
                    rows: [
                        EvidenceRow(
                            label: "Package created",
                            value: formatted(
                                provenance.packageCreatedAt
                            ),
                            symbol: "shippingbox",
                            tint: PPColor.textSecondary
                        ),
                        EvidenceRow(
                            label: "Verified at",
                            value: formatted(provenance.verifiedAt),
                            symbol: "checkmark.shield",
                            tint: PPColor.mint
                        ),
                        EvidenceRow(
                            label: "Imported at",
                            value: formatted(provenance.importedAt),
                            symbol: "tray.and.arrow.down",
                            tint: PPColor.cyan
                        )
                    ]
                )

                fingerprintSection(provenance)

                Label(
                    isCurrent
                        ? "Receipt signature and exact PDF bytes were checked locally."
                        : "Verification applies to the received bytes. Verify the edited copy again before delivery.",
                    systemImage: isCurrent
                        ? "iphone"
                        : "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(
                    isCurrent
                        ? PPColor.textSecondary
                        : PPColor.amber
                )
                .fixedSize(horizontal: false, vertical: true)

                if !isCurrent {
                    Button {
                        onVerify()
                    } label: {
                        Label(
                            "Verify Current PDF",
                            systemImage: "checkmark.shield"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .accessibilityIdentifier(
                        "verifyChangedReceivedPackage"
                    )
                }
            }
            .frame(maxWidth: 720)
            .padding(PPSpacing.regular)
            .frame(maxWidth: .infinity)
        }
    }

    private func evidenceSection(
        eyebrow: String,
        title: String,
        rows: [EvidenceRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            WorkflowSectionHeader(
                eyebrow: eyebrow,
                title: title
            )
            VStack(spacing: 0) {
                ForEach(
                    Array(rows.enumerated()),
                    id: \.offset
                ) { entry in
                    provenanceRow(entry.element)
                    if entry.offset < rows.count - 1 {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.52))
                            .frame(height: 0.6)
                    }
                }
            }
        }
    }

    private func fingerprintSection(
        _ provenance: PDFReceivedPackageProvenance
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            WorkflowSectionHeader(
                eyebrow: "BYTE IDENTITY",
                title: "SHA-256 fingerprint"
            )
            Text(provenance.artifactSHA256.uppercased())
                .font(.caption.monospaced())
                .foregroundStyle(PPColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    AppLocalization.format(
                        "SHA-256 fingerprint %@",
                        provenance.artifactSHA256.uppercased()
                    )
                )
            Button {
                fingerprintCopy.copy(provenance.artifactSHA256)
            } label: {
                Label(
                    fingerprintCopy.status
                        .fingerprintActionTitle.localizedUI,
                    systemImage:
                        fingerprintCopy.status.fingerprintActionSymbol
                )
            }
            .buttonStyle(
                PPQuietButtonStyle(
                    tint: fingerprintCopy.status.fingerprintTint
                )
            )
            .accessibilityLabel(
                fingerprintCopy.status
                    .fingerprintActionTitle.localizedUI
            )
            .accessibilityHint(
                (
                    fingerprintCopy.status == .copied
                        ? "Copies again and restarts the five-minute expiry."
                        : "Copies the full SHA-256 fingerprint locally for five minutes."
                ).localizedUI
            )
            SecureFingerprintCopyStatusLabel(
                status: fingerprintCopy.status
            )
            .font(.caption.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func provenanceRow(_ row: EvidenceRow) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            Image(systemName: row.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(row.tint)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label.localizedUI)
                    .font(.caption2.smallCaps().weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                Text(row.value.localizedUI)
                    .font(.caption)
                    .fontDesign(row.usesMonospacedText
                        ? .monospaced
                        : .default)
                    .foregroundStyle(PPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .combine)
    }

    private func signerTint(
        _ status: PDFOfficeSignerTrustStatus
    ) -> Color {
        switch status {
        case .thisDevice, .trusted:
            return PPColor.mint
        case .unknown:
            return PPColor.amber
        case .invalid, .unsupported:
            return PPColor.rose
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private struct EvidenceRow {
        let label: String
        let value: String
        let symbol: String
        let tint: Color

        var usesMonospacedText: Bool {
            label == "Package ID"
                || label == "Receipt ID"
                || label == "Signer Key ID"
        }
    }
}

struct DeliveryHistoryView: View {
    private enum HistoryScope: String, CaseIterable, Identifiable {
        case all
        case currentSource

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All revisions"
            case .currentSource: return "Current source"
            }
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let sourceRecordID: UUID
    let onOpen: (DocumentRoute) -> Void
    let onVerify: () -> Void
    @State private var selectedReceiptOutput: DocumentRecord?
    @State private var pendingReceiptRoute: DocumentRoute?
    @State private var receiptRouteTask: Task<Void, Never>?
    @State private var receiptRouteGeneration = UUID()
    @State private var selectionFeedback = 0
    @State private var scope = HistoryScope.all
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if let source = model.record(id: sourceRecordID) {
                    let outputs = model.deliveryHistoryOutputs(
                        for: sourceRecordID
                    )
                    let currentOutputIDs = Set(
                        model.verifiedOutputs(for: sourceRecordID).map(\.id)
                    )
                    let visibleOutputs = outputs.filter {
                        (scope == .all || currentOutputIDs.contains($0.id))
                            && matchesSearch($0)
                    }
                    if outputs.isEmpty {
                        VStack(spacing: PPSpacing.medium) {
                            ContentUnavailableView(
                                "No verified outputs",
                                systemImage: "clock.badge.questionmark",
                                description: Text(
                                    "Verified copies and checked exports appear here."
                                )
                            )
                            Button {
                                selectionFeedback &+= 1
                                onVerify()
                            } label: {
                                Label(
                                    "Verify Current PDF",
                                    systemImage: "checkmark.shield"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PPPrimaryButtonStyle())
                            .accessibilityIdentifier(
                                "verifyFromEmptyDeliveryHistory"
                            )
                        }
                        .frame(maxWidth: 520)
                        .padding(PPSpacing.regular)
                    } else {
                        ScrollView {
                            VStack(
                                alignment: .leading,
                                spacing: PPSpacing.large
                            ) {
                                VStack(
                                    alignment: .leading,
                                    spacing: PPSpacing.small
                                ) {
                                    Text(source.displayName)
                                        .font(.title3.bold())
                                        .fontDesign(.serif)
                                        .foregroundStyle(PPColor.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(
                                        AppLocalization.format(
                                            "%lld outputs · %lld from current source",
                                            outputs.count,
                                            currentOutputIDs.count
                                        )
                                    )
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(PPColor.textSecondary)
                                    historyScopePicker
                                }

                                if visibleOutputs.isEmpty {
                                    ContentUnavailableView(
                                        "No matching outputs".localizedUI,
                                        systemImage: "line.3.horizontal.decrease.circle"
                                    )
                                    Button {
                                        scope = .all
                                        searchText = ""
                                    } label: {
                                        Label(
                                            "Show all outputs".localizedUI,
                                            systemImage: "line.3.horizontal.decrease"
                                        )
                                    }
                                    .buttonStyle(PPQuietButtonStyle())
                                } else {
                                    LazyVStack(spacing: PPSpacing.medium) {
                                        ForEach(visibleOutputs) { output in
                                            outputRow(
                                                output,
                                                isCurrentSource: currentOutputIDs.contains(output.id)
                                            )
                                        }
                                    }
                                }

                                Button {
                                    selectionFeedback &+= 1
                                    onVerify()
                                } label: {
                                    Label(
                                        "Verify Current PDF",
                                        systemImage: "checkmark.shield"
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(PPPrimaryButtonStyle())
                                .accessibilityHint(
                                    "Creates another checked output from the current working copy."
                                        .localizedUI
                                )
                                .accessibilityIdentifier(
                                    "verifyFromDeliveryHistory"
                                )
                            }
                            .frame(maxWidth: 680)
                            .padding(PPSpacing.regular)
                            .frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Source unavailable",
                        systemImage: "doc.questionmark"
                    )
                }
            }
            .searchable(
                text: $searchText,
                prompt: Text("Search outputs".localizedUI)
            )
            .navigationTitle("Delivery history".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onChange(of: sourceRecordID) { _, _ in
            scope = .all
            searchText = ""
            interruptReceiptNavigation()
        }
        .sheet(
            item: $selectedReceiptOutput,
            onDismiss: completeReceiptRoute
        ) { output in
            DeliveryReceiptView(
                recordID: output.id,
                onOpenRoute: { route in
                    pendingReceiptRoute = route
                    selectedReceiptOutput = nil
                }
            )
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptReceiptNavigation()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptReceiptNavigation()
        }
        .onDisappear {
            interruptReceiptNavigation()
        }
        .accessibilityAction(.escape) {
            dismiss()
        }
        .sensoryFeedback(.selection, trigger: selectionFeedback)
    }

    private func outputRow(
        _ output: DocumentRecord,
        isCurrentSource: Bool
    ) -> some View {
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

        return layout {
            Button {
                selectionFeedback &+= 1
                onOpen(
                    DocumentRoute(
                        recordID: output.id,
                        expectedContentRevisionID:
                            output.contentRevisionID
                    )
                )
            } label: {
                HStack(spacing: PPSpacing.medium) {
                    if let url = model.url(for: output.id),
                       !output.profile.isLocked {
                        PDFPageThumbnailView(
                            url: url,
                            pageIndex: 0,
                            refreshToken: model.refreshToken(
                                for: output.id
                            ),
                            width: 54
                        )
                    } else {
                        ToolSymbolPlate(
                            symbol:
                                output.deliveryReceipt?.operation.symbol
                                    ?? "doc",
                            tint: PPColor.mint,
                            size: 48
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            output.deliveryReceipt?.operation.title.localizedUI
                                ?? output.displayName
                        )
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? nil
                                : 2
                        )
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )

                        Text(output.displayName)
                            .font(.caption)
                            .foregroundStyle(
                                PPColor.textSecondary
                            )
                            .lineLimit(
                                dynamicTypeSize.ppPrefersExpandedLayout
                                    ? nil
                                    : 1
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )

                        if let receipt = output.deliveryReceipt {
                            Label(
                                (
                                    !output.hasCurrentDeliveryReceipt
                                        ? "Receipt needs recheck"
                                        : receipt.hasWarnings
                                            ? "Needs review"
                                            : isCurrentSource
                                                ? "Current source"
                                                : "Earlier source revision"
                                ).localizedUI,
                                systemImage: !output.hasCurrentDeliveryReceipt || receipt.hasWarnings
                                    ? "exclamationmark.triangle"
                                    : isCurrentSource ? "checkmark.seal" : "clock"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(
                                !output.hasCurrentDeliveryReceipt || receipt.hasWarnings
                                    ? PPColor.amber : isCurrentSource ? PPColor.mint : PPColor.textSecondary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            Text(
                                "\(receipt.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(receipt.formattedOutputSize)"
                            )
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(
                                PPColor.textSecondary
                            )
                            .lineLimit(
                                dynamicTypeSize.ppPrefersExpandedLayout
                                    ? nil
                                    : 1
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                        }
                    }

                    Spacer(minLength: PPSpacing.small)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PPColor.mint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this saved output".localizedUI)
            .help("Open PDF".localizedUI)
            .hoverEffect(.highlight)

            if output.deliveryReceipt != nil {
                Button {
                    selectionFeedback &+= 1
                    selectedReceiptOutput = output
                } label: {
                    Label(
                        "Receipt",
                        systemImage: "checkmark.seal"
                    )
                    .frame(
                        maxWidth:
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? .infinity
                                : nil
                    )
                }
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.cyan)
                )
                .accessibilityHint(
                    "Opens verification evidence without leaving output history."
                        .localizedUI
                )
                .accessibilityIdentifier(
                    "openOutputReceipt-\(output.id.uuidString)"
                )
                .help("Receipt".localizedUI)
            }
        }
        .padding(PPSpacing.medium)
        .ppPaper(cornerRadius: 8, shadow: false)
    }

    private func matchesSearch(_ output: DocumentRecord) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return output.displayName.localizedStandardContains(query)
            || output.deliveryReceipt?.operation.title.localizedUI
                .localizedStandardContains(query) == true
    }

    @ViewBuilder
    private var historyScopePicker: some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            Picker("Output revisions".localizedUI, selection: $scope) {
                ForEach(HistoryScope.allCases) { option in
                    Text(option.title.localizedUI).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            .accessibilityIdentifier("deliveryHistoryScope")
        } else {
            Picker("Output revisions".localizedUI, selection: $scope) {
                ForEach(HistoryScope.allCases) { option in
                    Text(option.title.localizedUI).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("deliveryHistoryScope")
        }
    }

    private func completeReceiptRoute() {
        guard let route = pendingReceiptRoute else { return }
        pendingReceiptRoute = nil
        receiptRouteTask?.cancel()
        let generation = UUID()
        receiptRouteGeneration = generation
        receiptRouteTask = Task { @MainActor in
            defer {
                if receiptRouteGeneration == generation {
                    receiptRouteTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  receiptRouteGeneration == generation,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  model.record(id: route.recordID) != nil
            else { return }
            onOpen(route)
        }
    }

    private func interruptReceiptNavigation() {
        receiptRouteGeneration = UUID()
        receiptRouteTask?.cancel()
        receiptRouteTask = nil
        pendingReceiptRoute = nil
        selectedReceiptOutput = nil
    }
}

struct DeliveryReceiptView: View {
    private enum ShareArtifactKind: Equatable {
        case pdf
        case deliveryPackage
        case changeReport
    }

    private struct PendingMilestonePageOpen {
        let recordID: UUID
        let pageIndex: Int
        let contentRevisionID: UUID
    }

    private struct DeliveryChangeTarget {
        let recordID: UUID
        let pageIndex: Int
        let contentRevisionID: UUID
    }

    private struct MilestoneEvidenceTaskID: Hashable {
        let receiptID: UUID?
        let contentRevisionID: UUID?
        let storageRevision: Int
        let canReadProtectedData: Bool
        let request: Int
    }

    @EnvironmentObject private var model: PaperPathModel
    @EnvironmentObject private var purchase: PurchaseController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let receiptOverride: PDFDeliveryReceipt?
    let linkedMilestoneOverride: PDFVersionSnapshot?
    let onOpenRoute: (DocumentRoute) -> Void
    @StateObject private var fingerprintCopy =
        SecurePasteboardCopyController()
    @State private var protectedMilestoneCount = 0
    @State private var preparedShareCount = 0
    @State private var isSharing = false
    @State private var shareURL: URL?
    @State private var shareArtifactKind:
        ShareArtifactKind?
    @State private var preparingShareArtifactKind:
        ShareArtifactKind?
    @State private var milestoneEvidence:
        PDFDeliveryMilestoneEvidence?
    @State private var milestoneEvidenceErrorMessage: String?
    @State private var milestoneEvidenceErrorFeedback = 0
    @State private var milestoneEvidenceReloadRequest = 0
    @State private var protectedDataAvailable =
        UIApplication.shared.isProtectedDataAvailable
    @State private var milestoneEvidenceReceiptID: UUID?
    @State private var milestoneEvidenceContentRevisionID: UUID?
    @State private var selectedMilestone: PDFVersionSnapshot?
    @State private var recheckTask: Task<Void, Never>?
    @State private var recheckStopRequested = false
    @State private var milestoneProtectionTask:
        Task<Void, Never>?
    @State private var milestoneProtectionStopRequested = false
    @State private var sharePreparationTask:
        Task<Void, Never>?
    @State private var pdfShareProgress: PDFOperationProgress?
    @State private var pdfShareRateWindow = ByteRateWindow()
    @State private var milestoneEvidenceGeneration = UUID()
    @State private var recheckGeneration = UUID()
    @State private var milestoneProtectionGeneration = UUID()
    @State private var sharePreparationGeneration = UUID()
    @State private var isPresentingVerifiedOutputUnlock = false
    @State private var showsVerificationDetails = false
    @State private var hasReviewedWarnings = false
    @State private var verificationScrollRequest = 0
    @State private var pendingWarningShareArtifactKind:
        ShareArtifactKind?
    @State private var pendingMilestonePageOpen:
        PendingMilestonePageOpen?
    @State private var milestoneNavigationTask:
        Task<Void, Never>?
    @State private var milestoneNavigationGeneration = UUID()
    @State private var milestoneNavigationFeedback = 0
    @State private var showsAllLinkedMilestones = false
    @State private var resumesRecheckAfterUnlock = false
    @State private var unlockContinuationTask:
        Task<Void, Never>?

    init(
        recordID: UUID,
        receiptOverride: PDFDeliveryReceipt? = nil,
        linkedMilestoneOverride: PDFVersionSnapshot? = nil,
        onOpenRoute: @escaping (DocumentRoute) -> Void
    ) {
        self.recordID = recordID
        self.receiptOverride = receiptOverride
        self.linkedMilestoneOverride = linkedMilestoneOverride
        self.onOpenRoute = onOpenRoute
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if let record = model.record(id: recordID),
                   let receipt = displayedReceipt {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(
                                alignment: .leading,
                                spacing: PPSpacing.xLarge
                            ) {
                                certificate(
                                    record: record,
                                    receipt: receipt
                                )
                                if !isCurrent(
                                    receipt: receipt,
                                    for: record
                                ) || receipt.hasWarnings {
                                    deliveryDecisionPanel(
                                        record: record,
                                        receipt: receipt
                                    )
                                }
                                if isCurrent(
                                    receipt: receipt,
                                    for: record
                                ) {
                                    primaryShareAction(receipt)
                                }
                                verificationDetails(
                                    record: record,
                                    receipt: receipt
                                )
                                .id("deliveryVerificationDetails")
                            }
                            .frame(maxWidth: 680)
                            .padding(PPSpacing.regular)
                            .frame(maxWidth: .infinity)
                        }
                        .onChange(
                            of: verificationScrollRequest
                        ) { _, request in
                            guard request > 0 else { return }
                            withAnimation(
                                reduceMotion
                                    ? nil
                                    : .snappy(duration: 0.22)
                            ) {
                                proxy.scrollTo(
                                    "deliveryVerificationDetails",
                                    anchor: .top
                                )
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No delivery receipt",
                        systemImage: "doc.questionmark",
                        description: Text(
                            "This working copy was not created by a verified output operation."
                        )
                    )
                }
            }
            .navigationTitle("Delivery receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        (
                            hasRequestedTaskStop
                                ? "Stopping"
                                : hasActiveTask
                                    ? "Stop"
                                    : "Close"
                        ).localizedUI
                    ) {
                        if hasActiveTask {
                            stopActiveTask()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(hasRequestedTaskStop)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .sheet(
            isPresented: $isSharing,
            onDismiss: cleanupPreparedShare
        ) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(
            item: $selectedMilestone,
            onDismiss: {
                milestoneEvidenceReloadRequest &+= 1
                completeMilestonePageOpen()
            }
        ) { milestone in
            PDFVersionHistoryView(
                recordID: recordID,
                initialVersionID: milestone.id,
                onOpenPage: { targetRecordID, pageIndex in
                    guard let contentRevisionID =
                        model.record(id: targetRecordID)?
                            .contentRevisionID
                    else {
                        model[noticeFor: paperPathSceneID] =
                            "The document is no longer available"
                                .localizedUI
                        selectedMilestone = nil
                        return
                    }
                    pendingMilestonePageOpen =
                        PendingMilestonePageOpen(
                            recordID: targetRecordID,
                            pageIndex: pageIndex,
                            contentRevisionID: contentRevisionID
                        )
                    selectedMilestone = nil
                }
            )
        }
        .sheet(
            isPresented: $isPresentingVerifiedOutputUnlock,
            onDismiss: completeVerifiedOutputUnlock
        ) {
            FullUnlockView(context: .singleVerifiedOutput)
        }
        .task(id: milestoneEvidenceTaskID) {
            let receiptID = displayedReceipt?.id
            let revisionID = model.record(id: recordID)?.contentRevisionID
            if milestoneEvidenceReceiptID != receiptID
                || milestoneEvidenceContentRevisionID != revisionID {
                milestoneEvidenceReceiptID = receiptID
                milestoneEvidenceContentRevisionID = revisionID
                hasReviewedWarnings = false
                pendingWarningShareArtifactKind = nil
                showsAllLinkedMilestones = false
                fingerprintCopy.reset()
                stopSharePreparation()
                isSharing = false
                cleanupPreparedShare()
            }
            milestoneEvidenceGeneration = UUID()
            milestoneEvidence = nil
            milestoneEvidenceErrorMessage = nil
            guard canReadProtectedEvidence else { return }
            await loadMilestoneEvidence()
        }
        .onDisappear {
            interruptProtectedReceiptWork()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                fingerprintCopy.synchronizeOwnership()
            } else if phase == .background {
                interruptProtectedReceiptWork()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIPasteboard.changedNotification
            )
        ) { _ in
            fingerprintCopy.synchronizeOwnership()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            protectedDataAvailable = false
            interruptProtectedReceiptWork()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            protectedDataAvailable = true
        }
        .interactiveDismissDisabled(hasActiveTask)
        .confirmationDialog(
            warningShareTitle,
            isPresented: Binding(
                get: { pendingWarningShareArtifactKind != nil },
                set: {
                    if !$0 {
                        pendingWarningShareArtifactKind = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Review Details".localizedUI) {
                pendingWarningShareArtifactKind = nil
                hasReviewedWarnings = true
                showsVerificationDetails = true
                verificationScrollRequest &+= 1
            }
            .accessibilityIdentifier("reviewWarningDetails")
            if hasReviewedWarnings {
                Button("Share Anyway".localizedUI, role: .destructive) {
                    continueWarningShare()
                }
                .accessibilityIdentifier("confirmWarningShare")
            }
            Button("Cancel".localizedUI, role: .cancel) {
                pendingWarningShareArtifactKind = nil
            }
        } message: {
            Text(warningShareMessage)
        }
        .accessibilityAction(.escape) {
            if hasActiveTask {
                stopActiveTask()
            } else {
                dismiss()
            }
        }
        .sensoryFeedback(
            .success,
            trigger: fingerprintCopy.successFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: fingerprintCopy.errorFeedback
        )
        .sensoryFeedback(
            .success,
            trigger: protectedMilestoneCount
        )
        .sensoryFeedback(
            .success,
            trigger: preparedShareCount
        )
        .sensoryFeedback(
            .error,
            trigger: milestoneEvidenceErrorFeedback
        )
        .sensoryFeedback(
            .selection,
            trigger: milestoneNavigationFeedback
        )
    }

    private var milestoneEvidenceTaskID: MilestoneEvidenceTaskID {
        MilestoneEvidenceTaskID(
            receiptID: displayedReceipt?.id,
            contentRevisionID: model.record(id: recordID)?.contentRevisionID,
            storageRevision: model.retainedEvidenceRevision,
            canReadProtectedData: canReadProtectedEvidence,
            request: milestoneEvidenceReloadRequest
        )
    }

    private var canReadProtectedEvidence: Bool {
        scenePhase == .active
            && protectedDataAvailable
            && UIApplication.shared.isProtectedDataAvailable
    }

    private var displayedReceipt: PDFDeliveryReceipt? {
        receiptOverride
            ?? model.record(id: recordID)?.deliveryReceipt
    }

    private func isCurrent(
        receipt: PDFDeliveryReceipt,
        for record: DocumentRecord
    ) -> Bool {
        record.deliveryReceipt?.id == receipt.id
            && record.hasCurrentDeliveryReceipt
    }

    private func verificationDetails(
        record: DocumentRecord,
        receipt: PDFDeliveryReceipt
    ) -> some View {
        DisclosureGroup(
            isExpanded: $showsVerificationDetails
        ) {
            VStack(
                alignment: .leading,
                spacing: PPSpacing.xLarge
            ) {
                OfficeClockContinuitySection()
                if let source = model.sourceRecord(for: record) {
                    lineage(source)
                }
                if receipt.isVerified {
                    milestoneEvidenceSection(record: record)
                }
                LinkedChangeReportSection(
                    lookup: .deliveryReceipt(
                        recordID: record.id,
                        receiptID: receipt.id
                    )
                )
                if let review = receipt.changeReview {
                    PDFChangeReviewSummary(
                        review: review,
                        context: .delivery,
                        isExportingReport:
                            preparingShareArtifactKind == .changeReport,
                        onOpenChange: { change in
                            guard let target = deliveryChangeTarget(
                                change,
                                output: record,
                                receipt: receipt
                            )
                            else { return }
                            requestOpenPage(target)
                        },
                        onExportReport: {
                            prepareChangeReport(
                                review: review,
                                record: record,
                                receipt: receipt
                            )
                        }
                    )
                }
                metrics(receipt)
                checks(receipt)
                fingerprint(receipt)
                scope
            }
            .padding(.top, PPSpacing.medium)
        } label: {
            HStack(spacing: PPSpacing.medium) {
                Image(systemName: "checkmark.shield")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PPColor.cyan)
                    .frame(width: 32, height: 32)
                    .background(
                        PPColor.cyan.opacity(0.1),
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verification details".localizedUI)
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(
                        "Checks, history, and file fingerprint"
                            .localizedUI
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                }
            }
        }
        .tint(PPColor.cyan)
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.7)
        }
    }

    private func certificate(
        record: DocumentRecord,
        receipt: PDFDeliveryReceipt
    ) -> some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 22))
        let isCurrent = isCurrent(receipt: receipt, for: record)
        let replacement = isCurrent
            ? nil
            : model.verifiedShareTarget(for: record.id)

        return layout {
            ZStack(alignment: .bottomTrailing) {
                if let url = model.url(for: recordID),
                   !record.profile.isLocked {
                    PDFPageThumbnailView(
                        url: url,
                        pageIndex: 0,
                        refreshToken: model.refreshToken(for: recordID),
                        width: 92
                    )
                    .rotationEffect(.degrees(-2))
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 5)
                } else {
                    sealedDocument
                }

                DeliverySealIllustration(
                    warning: receipt.hasWarnings
                )
                .frame(width: 70, height: 70)
                .offset(x: 22, y: 17)
            }
            .frame(
                width: dynamicTypeSize.ppPrefersExpandedLayout
                    ? 132
                    : 122,
                height: 132
            )

            VStack(alignment: .leading, spacing: PPSpacing.small) {
                SectionEyebrow(
                    text: isCurrent
                        ? (
                            receipt.isDeliveryOutput
                                ? "FINAL COPY CHECKED"
                                : "PRIVATE COPY CHECKED"
                        )
                        : "OUTPUT CHANGED"
                )
                Text(
                    (
                        isCurrent
                            ? receipt.outcomeTitle
                                : replacement == nil
                                    ? "Verify again"
                                    : "New verified copy ready"
                    ).localizedUI
                )
                    .font(.title.bold())
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    (
                        isCurrent
                            ? receipt.outcomeDetail
                                : replacement == nil
                                    ? "This file changed after its receipt was created."
                                    : "A newer checked copy now protects these changes."
                    ).localizedUI
                )
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "\(receipt.operation.title.localizedUI) · \(record.displayName)"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
                DeliveryReceiptBadge(
                    receipt: receipt,
                    isCurrent: isCurrent
                )
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.7)
        }
    }

    private func primaryShareAction(
        _ receipt: PDFDeliveryReceipt
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Button {
                requestShare(.pdf, receipt: receipt)
            } label: {
                Label(
                    preparingShareArtifactKind == .pdf
                        ? "Preparing share"
                        : shareTitle(for: receipt),
                    systemImage: "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(hasActiveTask)
            .accessibilityHint(
                (
                    activeTaskDescription
                        ?? "Shares a protected copy of this checked PDF."
                ).localizedUI
            )
            .accessibilityIdentifier(
                receipt.isDeliveryOutput
                    ? "shareVerifiedOutput"
                    : "shareCheckedOutput"
            )

            Button {
                requestShare(.deliveryPackage, receipt: receipt)
            } label: {
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "archivebox")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.mint)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share PDF + Receipt".localizedUI)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Text(
                            "One ZIP with the exact PDF and a signed verification manifest."
                                .localizedUI
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        if let keyID =
                            model.officeDeliverySigningKeyID {
                            Text(
                                AppLocalization.format(
                                    "Device signature · %@",
                                    String(keyID.prefix(8)).uppercased()
                                )
                            )
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(PPColor.textSecondary)
                        }
                    }
                    Spacer(minLength: PPSpacing.small)
                    if preparingShareArtifactKind == .deliveryPackage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.mint)
                    }
                }
                .padding(.vertical, PPSpacing.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(hasActiveTask)
            .accessibilityHint(
                (
                    activeTaskDescription
                        ?? "Creates a local package that keeps the PDF and its verification evidence together."
                ).localizedUI
            )
            .accessibilityIdentifier("shareDeliveryPackage")

            if preparingShareArtifactKind == .pdf,
               let pdfShareProgress {
                VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                    LocalOperationProgressView(
                        progress: pdfShareProgress
                    )
                    Button("Stop preparing share") {
                        stopSharePreparation()
                    }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                    .foregroundStyle(PPColor.amber)
                }
                .padding(.vertical, PPSpacing.xSmall)
            } else if preparingShareArtifactKind == .deliveryPackage,
               let progress = model.progress(for: recordID),
               progress.label == "Packaging verified PDF" {
                VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                    LocalOperationProgressView(progress: progress)
                    Button("Stop packaging") {
                        stopSharePreparation()
                    }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                    .foregroundStyle(PPColor.amber)
                    .accessibilityIdentifier("stopDeliveryPackage")
                }
                .padding(.vertical, PPSpacing.xSmall)
            } else {
                Text(
                    AppLocalization.format(
                        "Separate checked copy · %lld pages · %@",
                        receipt.outputPageCount,
                        receipt.formattedOutputSize
                    )
                )
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(PPColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func deliveryDecisionPanel(
        record: DocumentRecord,
        receipt: PDFDeliveryReceipt
    ) -> some View {
        let isCurrent = isCurrent(receipt: receipt, for: record)
        let visibleChanges = receipt.changeReview?.majorVisibleChanges.count
            ?? 0
        let replacement = isCurrent
            ? nil
            : model.verifiedShareTarget(for: record.id)
        let tint: Color = isCurrent
            ? (receipt.hasWarnings ? PPColor.amber : PPColor.mint)
            : PPColor.amber

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.medium) {
                Image(
                    systemName: isCurrent
                        ? receipt.operation.symbol
                        : "arrow.triangle.2.circlepath"
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.1), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        (
                            isCurrent
                                ? "Delivery decision"
                                : replacement == nil
                                    ? "Recheck before sharing"
                                    : "Replacement verified"
                        ).localizedUI
                    )
                    .font(.headline)
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    Text(
                        (
                            isCurrent
                                ? receipt.outcomeDetail
                                : replacement == nil
                                    ? "The PDF changed after this receipt was issued."
                                    : "Open the newer verified copy to share it."
                        ).localizedUI
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? 4
                            : 2
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: PPSpacing.small)

            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.medium) {
                    deliveryDecisionFact(
                        isCurrent ? "Current" : "Expired",
                        label: "STATUS",
                        symbol: isCurrent
                            ? "checkmark.seal"
                            : "exclamationmark.triangle",
                        tint: tint
                    )
                    deliveryDecisionFact(
                        "\(receipt.warningCount)",
                        label: "WARN",
                        symbol: "exclamationmark.triangle",
                        tint: receipt.warningCount == 0
                            ? PPColor.mint
                            : PPColor.amber
                    )
                    deliveryDecisionFact(
                        "\(visibleChanges)",
                        label: "CHANGES",
                        symbol: "eye",
                        tint: visibleChanges == 0
                            ? PPColor.mint
                            : PPColor.cyan
                    )
                    deliveryDecisionFact(
                        receipt.shortFingerprint.uppercased(),
                        label: "SHA",
                        symbol: "number",
                        tint: PPColor.accent
                    )
                }
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    HStack(spacing: PPSpacing.medium) {
                        deliveryDecisionFact(
                            isCurrent ? "Current" : "Expired",
                            label: "STATUS",
                            symbol: isCurrent
                                ? "checkmark.seal"
                                : "exclamationmark.triangle",
                            tint: tint
                        )
                        deliveryDecisionFact(
                            "\(receipt.warningCount)",
                            label: "WARN",
                            symbol: "exclamationmark.triangle",
                            tint: receipt.warningCount == 0
                                ? PPColor.mint
                                : PPColor.amber
                        )
                    }
                    HStack(spacing: PPSpacing.medium) {
                        deliveryDecisionFact(
                            "\(visibleChanges)",
                            label: "CHANGES",
                            symbol: "eye",
                            tint: visibleChanges == 0
                                ? PPColor.mint
                                : PPColor.cyan
                        )
                        deliveryDecisionFact(
                            receipt.shortFingerprint.uppercased(),
                            label: "SHA",
                            symbol: "number",
                            tint: PPColor.accent
                        )
                    }
                }
            }

            deliveryDecisionActionMatrix(
                record: record,
                receipt: receipt,
                isCurrent: isCurrent,
                tint: tint
            )
            if recheckTask != nil {
                if let progress = model.progress(for: record.id) {
                    LocalOperationProgressView(progress: progress)
                } else {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Creating a new verified copy".localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 2)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .contain)
    }

    private func deliveryDecisionActionMatrix(
        record: DocumentRecord,
        receipt: PDFDeliveryReceipt,
        isCurrent: Bool,
        tint: Color
    ) -> some View {
        let firstChange = receipt.changeReview?.majorVisibleChanges.first
            ?? receipt.changeReview?.visibleChanges.first
        let replacement = isCurrent
            ? nil
            : model.verifiedShareTarget(for: record.id)
        let firstChangeTarget = firstChange.flatMap {
            deliveryChangeTarget(
                $0,
                output: record,
                receipt: receipt
            )
        }

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                deliveryDecisionActionButton(
                    isCurrent
                        ? decisionShareTitle(receipt)
                        : replacement != nil
                            ? "Open latest"
                            : recheckTask == nil
                            ? "Recheck"
                            : "Rechecking",
                    detail: isCurrent
                        ? decisionShareDetail(receipt)
                        : replacement == nil
                            ? "Verify changed output"
                            : "Verified copy",
                    symbol: isCurrent
                        ? "square.and.arrow.up"
                        : "arrow.triangle.2.circlepath",
                    tint: tint
                ) {
                    if isCurrent, receipt.isVerified {
                        requestShare(.pdf, receipt: receipt)
                    } else if let replacement {
                        requestOpenPage(
                            recordID: replacement.id,
                            pageIndex: 0,
                            contentRevisionID:
                                replacement.contentRevisionID
                        )
                    } else {
                        recheck(record)
                    }
                }
                .disabled(hasActiveTask)
                .accessibilityHint(
                    (
                        activeTaskDescription
                            ?? (
                                isCurrent
                                    ? "Shares this checked PDF."
                                    : replacement == nil
                                        ? "Creates a new verified copy."
                                        : "Opens the latest verified copy."
                            )
                    ).localizedUI
                )

                deliveryDecisionActionButton(
                    firstChange == nil ? "No visible drift" : "Open drift",
                    detail: firstChangeTarget.map {
                        "Page \($0.pageIndex + 1)"
                    } ?? "Pixel clear",
                    symbol: firstChange == nil
                        ? "eye.slash"
                        : "eye",
                    tint: firstChange == nil ? PPColor.mint : PPColor.cyan
                ) {
                    if let firstChangeTarget {
                        requestOpenPage(firstChangeTarget)
                    }
                }
                .disabled(
                    hasActiveTask || firstChangeTarget == nil
                )
                .accessibilityHint(
                    (
                        activeTaskDescription
                            ?? (
                                firstChangeTarget == nil
                                    ? "No visible change is available."
                                    : "Opens the first visible change."
                            )
                    ).localizedUI
                )

                fingerprintDecisionAction(receipt)
            }

            VStack(alignment: .leading, spacing: PPSpacing.small) {
                deliveryDecisionActionButton(
                    isCurrent
                        ? decisionShareTitle(receipt)
                        : replacement != nil
                            ? "Open latest"
                            : recheckTask == nil
                            ? "Recheck"
                            : "Rechecking",
                    detail: isCurrent
                        ? decisionShareDetail(receipt)
                        : replacement == nil
                            ? "Verify changed output"
                            : "Verified copy",
                    symbol: isCurrent
                        ? "square.and.arrow.up"
                        : "arrow.triangle.2.circlepath",
                    tint: tint
                ) {
                    if isCurrent, receipt.isVerified {
                        requestShare(.pdf, receipt: receipt)
                    } else if let replacement {
                        requestOpenPage(
                            recordID: replacement.id,
                            pageIndex: 0,
                            contentRevisionID:
                                replacement.contentRevisionID
                        )
                    } else {
                        recheck(record)
                    }
                }
                .disabled(hasActiveTask)
                .accessibilityHint(
                    (
                        activeTaskDescription
                            ?? (
                                isCurrent
                                    ? "Shares this checked PDF."
                                    : replacement == nil
                                        ? "Creates a new verified copy."
                                        : "Opens the latest verified copy."
                            )
                    ).localizedUI
                )

                deliveryDecisionActionButton(
                    firstChange == nil ? "No visible drift" : "Open drift",
                    detail: firstChangeTarget.map {
                        "Page \($0.pageIndex + 1)"
                    } ?? "Pixel clear",
                    symbol: firstChange == nil
                        ? "eye.slash"
                        : "eye",
                    tint: firstChange == nil ? PPColor.mint : PPColor.cyan
                ) {
                    if let firstChangeTarget {
                        requestOpenPage(firstChangeTarget)
                    }
                }
                .disabled(
                    hasActiveTask || firstChangeTarget == nil
                )
                .accessibilityHint(
                    (
                        activeTaskDescription
                            ?? (
                                firstChangeTarget == nil
                                    ? "No visible change is available."
                                    : "Opens the first visible change."
                            )
                    ).localizedUI
                )

                fingerprintDecisionAction(receipt)
            }
        }
        .padding(.top, PPSpacing.xSmall)
    }

    private func fingerprintDecisionAction(
        _ receipt: PDFDeliveryReceipt
    ) -> some View {
        deliveryDecisionActionButton(
            fingerprintCopy.status.fingerprintActionTitle,
            detail: fingerprintCopyDetail(receipt),
            symbol: fingerprintCopy.status.fingerprintActionSymbol,
            tint: fingerprintCopy.status.fingerprintTint
        ) {
            fingerprintCopy.copy(receipt.sha256)
        }
        .accessibilityHint(fingerprintCopyAccessibilityHint)
    }

    private func fingerprintCopyDetail(
        _ receipt: PDFDeliveryReceipt
    ) -> String {
        switch fingerprintCopy.status {
        case .idle:
            return receipt.shortFingerprint.uppercased()
        case .copied:
            return "Available for five minutes".localizedUI
        case .failed:
            return "Tap to try again".localizedUI
        }
    }

    private var fingerprintCopyAccessibilityHint: String {
        (
            fingerprintCopy.status == .copied
                ? "Copies again and restarts the five-minute expiry."
                : "Copies the full SHA-256 fingerprint locally for five minutes."
        ).localizedUI
    }

    private func decisionShareTitle(
        _ receipt: PDFDeliveryReceipt
    ) -> String {
        receipt.hasWarnings ? "Share with warning" : "Share"
    }

    private func decisionShareDetail(
        _ receipt: PDFDeliveryReceipt
    ) -> String {
        guard receipt.hasWarnings else { return "Current copy" }
        return AppLocalization.format(
            "%lld warnings",
            receipt.warningCount
        )
    }

    private func deliveryChangeTarget(
        _ change: PDFPageChange,
        output: DocumentRecord,
        receipt: PDFDeliveryReceipt
    ) -> DeliveryChangeTarget? {
        switch change.preferredOpenSide {
        case .revised:
            guard let pageIndex = change.resolvedRevisedPageIndex,
                  let revisionID = receipt.outputRevisionID
                    ?? (
                        isCurrent(receipt: receipt, for: output)
                            ? output.contentRevisionID
                            : nil
                    )
            else {
                return nil
            }
            return DeliveryChangeTarget(
                recordID: output.id,
                pageIndex: pageIndex,
                contentRevisionID: revisionID
            )
        case .source:
            guard let source = model.sourceRecord(for: output),
                  let pageIndex = change.resolvedSourcePageIndex,
                  let revisionID = receipt.sourceRevisionID
            else { return nil }
            return DeliveryChangeTarget(
                recordID: source.id,
                pageIndex: pageIndex,
                contentRevisionID: revisionID
            )
        }
    }

    private func requestOpenPage(
        _ target: DeliveryChangeTarget
    ) {
        requestOpenPage(
            recordID: target.recordID,
            pageIndex: target.pageIndex,
            contentRevisionID: target.contentRevisionID
        )
    }

    private func requestOpenPage(
        recordID: UUID,
        pageIndex: Int,
        contentRevisionID: UUID
    ) {
        onOpenRoute(
            DocumentRoute(
                recordID: recordID,
                pageIndex: pageIndex,
                expectedContentRevisionID:
                    contentRevisionID
            )
        )
    }

    private func requestShare(
        _ kind: ShareArtifactKind,
        receipt: PDFDeliveryReceipt
    ) {
        guard !hasActiveTask else { return }
        guard receipt.hasWarnings else {
            beginShare(kind)
            return
        }
        pendingWarningShareArtifactKind = kind
        if !hasReviewedWarnings {
            showsVerificationDetails = true
        }
    }

    private func continueWarningShare() {
        guard let kind = pendingWarningShareArtifactKind else { return }
        pendingWarningShareArtifactKind = nil
        beginShare(kind)
    }

    private func beginShare(_ kind: ShareArtifactKind) {
        switch kind {
        case .pdf:
            preparePDFShare()
        case .deliveryPackage:
            prepareDeliveryPackage()
        case .changeReport:
            break
        }
    }

    private var warningShareTitle: String {
        guard let receipt = displayedReceipt else {
            return "Share checked PDF?".localizedUI
        }
        return AppLocalization.format(
            "Share with %lld warnings?",
            receipt.warningCount
        )
    }

    private var warningShareMessage: String {
        guard hasReviewedWarnings else {
            return "Review warning details before sharing."
                .localizedUI
        }
        guard let warning = displayedReceipt?.checks.first(
            where: { $0.status == .warning }
        ) else {
            return "Review the warning before sharing this checked copy."
                .localizedUI
        }
        return "\(warning.title.localizedUI): \(warning.detail.localizedUI)"
    }

    private func recheck(_ record: DocumentRecord) {
        guard !hasActiveTask else { return }
        guard purchase.isUnlocked
                || model.verifiedOutputSuccessCount == 0
        else {
            resumesRecheckAfterUnlock = true
            isPresentingVerifiedOutputUnlock = true
            return
        }
        resumesRecheckAfterUnlock = false
        let generation = UUID()
        recheckGeneration = generation
        recheckStopRequested = false
        let previousOutputID = model.verifiedShareTarget(
            for: record.id
        )?.id
        let requestedRevisionID = record.contentRevisionID
        recheckTask = Task { @MainActor in
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createSafeShareCopy(
                    recordID: record.id,
                    expectedContentRevisionID:
                        requestedRevisionID
                )
            }
            guard recheckGeneration == generation else { return }
            let wasStopped =
                recheckStopRequested || Task.isCancelled
            recheckTask = nil
            recheckStopRequested = false
            let committed = created
                ?? model.verifiedShareTarget(for: record.id)
                    .flatMap {
                        $0.id == previousOutputID ? nil : $0
                    }
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    committed == nil
                        ? "Verification stopped · no output created"
                        : "Verification finished before stopping · output kept in Library"
                ).localizedUI
                return
            }
            guard let created else { return }
            requestOpenPage(
                recordID: created.id,
                pageIndex: 0,
                contentRevisionID: created.contentRevisionID
            )
        }
    }

    private func preparePDFShare() {
        guard !hasActiveTask else { return }
        cleanupPreparedShare()
        let generation = UUID()
        sharePreparationGeneration = generation
        preparingShareArtifactKind = .pdf
        pdfShareRateWindow.reset()
        pdfShareProgress = PDFOperationProgress(
            label: "Verifying protected share copy",
            fractionCompleted: 0,
            byteStage: .checksumming
        )
        sharePreparationTask = Task { @MainActor in
            let preparedURL = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.makeFilesExportCopy(
                    recordID: recordID
                ) { update in
                    guard sharePreparationGeneration == generation else {
                        return
                    }
                    if let progress =
                        pdfShareRateWindow.operationProgress(
                            label: "Verifying protected share copy",
                            update: update,
                            current: pdfShareProgress
                        ) {
                        pdfShareProgress = progress
                    }
                }
            }
            guard let url = preparedURL else {
                guard sharePreparationGeneration == generation else {
                    return
                }
                sharePreparationTask = nil
                preparingShareArtifactKind = nil
                pdfShareProgress = nil
                pdfShareRateWindow.reset()
                return
            }
            guard sharePreparationGeneration == generation else {
                await model.discardFilesExportCopy(at: url)
                return
            }
            guard !Task.isCancelled else {
                await model.discardFilesExportCopy(at: url)
                sharePreparationTask = nil
                preparingShareArtifactKind = nil
                pdfShareProgress = nil
                pdfShareRateWindow.reset()
                return
            }
            guard model.record(id: recordID)?
                    .hasCurrentDeliveryReceipt == true
            else {
                await model.discardFilesExportCopy(at: url)
                sharePreparationTask = nil
                preparingShareArtifactKind = nil
                pdfShareProgress = nil
                pdfShareRateWindow.reset()
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before sharing. Verify it again."
                        .localizedUI
                return
            }
            sharePreparationTask = nil
            preparingShareArtifactKind = nil
            pdfShareProgress = nil
            pdfShareRateWindow.reset()
            shareURL = url
            shareArtifactKind = .pdf
            preparedShareCount += 1
            isSharing = true
        }
    }

    private func prepareDeliveryPackage() {
        guard !hasActiveTask else { return }
        cleanupPreparedShare()
        let generation = UUID()
        sharePreparationGeneration = generation
        preparingShareArtifactKind = .deliveryPackage
        sharePreparationTask = Task { @MainActor in
            let preparedURL = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.makeDeliveryPackage(
                    recordID: recordID
                )
            }
            guard let url = preparedURL else {
                guard sharePreparationGeneration == generation else {
                    return
                }
                sharePreparationTask = nil
                preparingShareArtifactKind = nil
                return
            }
            guard sharePreparationGeneration == generation else {
                await model.discardDeliveryPackage(at: url)
                return
            }
            guard !Task.isCancelled else {
                await model.discardDeliveryPackage(at: url)
                sharePreparationTask = nil
                preparingShareArtifactKind = nil
                return
            }
            sharePreparationTask = nil
            preparingShareArtifactKind = nil
            shareURL = url
            shareArtifactKind = .deliveryPackage
            preparedShareCount += 1
            isSharing = true
        }
    }

    private func cleanupPreparedShare() {
        guard let shareURL,
              let shareArtifactKind
        else { return }
        self.shareURL = nil
        self.shareArtifactKind = nil
        Task {
            switch shareArtifactKind {
            case .pdf:
                await model.discardFilesExportCopy(at: shareURL)
            case .deliveryPackage:
                await model.discardDeliveryPackage(at: shareURL)
            case .changeReport:
                await model.discardChangeReport(at: shareURL)
            }
        }
    }

    private func prepareChangeReport(
        review: PDFChangeReview,
        record: DocumentRecord,
        receipt: PDFDeliveryReceipt
    ) {
        guard !hasActiveTask else { return }
        cleanupPreparedShare()
        let generation = UUID()
        sharePreparationGeneration = generation
        preparingShareArtifactKind = .changeReport
        let source = model.sourceRecord(for: record)
        let receiptIsCurrent = isCurrent(
            receipt: receipt,
            for: record
        )
        let descriptor = PDFChangeReportDescriptor(
            reportID: UUID(),
            scope: receiptIsCurrent
                ? "Verified output review".localizedUI
                : "Historical verified output review; the current PDF has changed"
                    .localizedUI,
            sourceName: source?.displayName ?? "Source PDF",
            revisedName: record.displayName,
            sourceRevisionID: receipt.sourceRevisionID,
            revisedRevisionID: receipt.outputRevisionID,
            sourceFingerprint:
                source?.contentRevisionID == receipt.sourceRevisionID
                    ? source?.contentFingerprint
                    : nil,
            revisedFingerprint: receipt.sha256,
            deliveryReceiptID: receipt.id,
            generatedAt: PDFOfficeTimeAnchor.process.trustedDate()
        )
        sharePreparationTask = Task { @MainActor in
            let url = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.makeChangeReport(
                    review: review,
                    descriptor: descriptor,
                    validatingRevisions: [
                        record.id: record.contentRevisionID
                    ],
                    localLink: receiptIsCurrent
                        ? PDFRetainedChangeReportLocalLink
                            .deliveryReceipt(
                                source: source,
                                revised: record,
                                receipt: receipt
                            )
                        : nil
                )
            }
            guard sharePreparationGeneration == generation else {
                if let url {
                    await model.discardChangeReport(at: url)
                }
                return
            }
            sharePreparationTask = nil
            preparingShareArtifactKind = nil
            guard !Task.isCancelled else {
                if let url {
                    await model.discardChangeReport(at: url)
                }
                return
            }
            guard let url else { return }
            shareURL = url
            shareArtifactKind = .changeReport
            preparedShareCount += 1
            isSharing = true
        }
    }

    private func deliveryDecisionActionButton(
        _ title: String,
        detail: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title.localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? nil
                                : 1
                        )
                    Text(detail.localizedUI)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? nil
                                : 1
                        )
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .background(tint.opacity(0.07))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tint.opacity(0.42))
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func deliveryDecisionFact(
        _ value: String,
        label: String,
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
                    .fontDesign(label == "SHA" ? .monospaced : .default)
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? nil
                            : 1
                    )
                Text(label.localizedUI)
                    .font(.caption2.smallCaps().weight(.medium))
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(
            minWidth: dynamicTypeSize.ppPrefersExpandedLayout
                ? nil
                : 92,
            maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                ? .infinity
                : nil,
            alignment: .leading
        )
        .accessibilityElement(children: .combine)
    }

    private func shareTitle(
        for receipt: PDFDeliveryReceipt
    ) -> String {
        if !receipt.isDeliveryOutput {
            return "Share editable PDF"
        }
        return receipt.hasWarnings
            ? "Share checked PDF"
            : "Share verified PDF"
    }

    private var sealedDocument: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(PPColor.surface)
                .frame(width: 92, height: 118)
                .shadow(color: .black.opacity(0.14), radius: 7, y: 4)
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.title3)
                    .foregroundStyle(PPColor.accent)
                Text("PROTECTED")
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .rotationEffect(.degrees(-2))
        .accessibilityHidden(true)
    }

    private func lineage(_ source: DocumentRecord) -> some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

        return Button {
            milestoneNavigationFeedback += 1
            requestOpenPage(
                recordID: source.id,
                pageIndex: source.lastPageIndex,
                contentRevisionID: source.contentRevisionID
            )
        } label: {
            layout {
                HStack(spacing: PPSpacing.medium) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PPColor.cyan)
                        .frame(width: 32, height: 32)
                        .background(
                            PPColor.cyan.opacity(0.08),
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CREATED FROM")
                            .font(
                                .caption2.smallCaps()
                                    .weight(.bold)
                            )
                            .foregroundStyle(PPColor.textSecondary)
                        Text(source.displayName)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(
                                dynamicTypeSize.ppPrefersExpandedLayout
                                    ? nil
                                    : 1
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                }

                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer(minLength: PPSpacing.small)
                }

                HStack(spacing: PPSpacing.xSmall) {
                    Text("SOURCE KEPT")
                        .font(
                            .caption2.smallCaps()
                                .weight(.bold)
                        )
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(PPColor.mint)
                .frame(
                    maxWidth:
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? .infinity
                            : nil,
                    alignment: .trailing
                )
            }
            .padding(PPSpacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ppPaper(cornerRadius: 10, shadow: false)
        .disabled(hasActiveTask)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AppLocalization.format(
                "Open source working copy %@",
                source.displayName
            )
        )
        .accessibilityHint(
            "Returns to the source PDF at its last viewed page."
                .localizedUI
        )
    }

    private var linkedMilestones: [PDFVersionSnapshot] {
        milestoneEvidence?.linkedMilestones ?? []
    }

    private var displayedLinkedMilestones: [PDFVersionSnapshot] {
        showsAllLinkedMilestones
            ? linkedMilestones
            : Array(linkedMilestones.prefix(4))
    }

    private func milestoneEvidenceSection(
        record: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "VERSION EVIDENCE",
                detail: milestoneEvidenceDetail,
                symbol: "point.3.connected.trianglepath.dotted",
                count: linkedMilestones.count,
                tint: PPColor.mint
            )

            if let milestoneEvidence {
                if linkedMilestones.isEmpty {
                    milestoneProtectionRow(
                        record: record,
                        availability: milestoneEvidence.availability
                    )
                } else {
                    ForEach(
                        Array(displayedLinkedMilestones.enumerated()),
                        id: \.element.id
                    ) { index, milestone in
                        let isOpening =
                            selectedMilestone?.id == milestone.id
                        Button {
                            openLinkedMilestone(milestone)
                        } label: {
                            let layout =
                                dynamicTypeSize
                                    .ppPrefersExpandedLayout
                                    ? AnyLayout(
                                        VStackLayout(
                                            alignment: .leading,
                                            spacing: PPSpacing.small
                                        )
                                    )
                                    : AnyLayout(
                                        HStackLayout(
                                            spacing: PPSpacing.medium
                                        )
                                    )
                            layout {
                                HStack(spacing: PPSpacing.medium) {
                                    Image(systemName: "pin.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(PPColor.mint)
                                        .frame(width: 24)
                                    VStack(
                                        alignment: .leading,
                                        spacing: 2
                                    ) {
                                        Text(milestone.displayTitle)
                                            .font(
                                                .subheadline
                                                    .weight(.semibold)
                                            )
                                            .fontDesign(.serif)
                                            .foregroundStyle(
                                                PPColor.textPrimary
                                            )
                                            .lineLimit(
                                                dynamicTypeSize
                                                    .ppPrefersExpandedLayout
                                                    ? nil
                                                    : 1
                                            )
                                            .fixedSize(
                                                horizontal: false,
                                                vertical: true
                                            )
                                        Text(
                                            "\(milestone.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(milestone.formattedSize)"
                                        )
                                        .font(
                                            .caption2.monospacedDigit()
                                        )
                                        .foregroundStyle(
                                            PPColor.textSecondary
                                        )
                                    }
                                    if !dynamicTypeSize
                                        .ppPrefersExpandedLayout {
                                        Spacer(minLength: 0)
                                    }
                                }

                                HStack(spacing: PPSpacing.xSmall) {
                                    Text(
                                        (
                                            isOpening
                                                ? "OPENING"
                                                : milestoneActionTitle(
                                                    milestone
                                                )
                                        ).localizedUI
                                    )
                                        .font(
                                            .caption2.smallCaps()
                                                .weight(.bold)
                                        )
                                    if isOpening {
                                        ProgressView()
                                            .controlSize(.mini)
                                            .frame(width: 14, height: 14)
                                    } else {
                                        Image(
                                            systemName:
                                                isReturningToPresentedVersion(
                                                    milestone
                                                )
                                                    ? "arrow.uturn.backward"
                                                    : "chevron.right"
                                        )
                                        .font(.caption2.weight(.bold))
                                    }
                                }
                                .foregroundStyle(
                                    isOpening ? PPColor.mint : PPColor.cyan
                                )
                                .frame(
                                    maxWidth:
                                        dynamicTypeSize
                                            .ppPrefersExpandedLayout
                                            ? .infinity
                                            : nil,
                                    alignment: .trailing
                                )
                            }
                            .padding(.vertical, PPSpacing.small)
                            .padding(.horizontal, PPSpacing.xSmall)
                            .background(
                                isOpening
                                    ? PPColor.cyan.opacity(0.08)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(alignment: .leading) {
                                if isOpening {
                                    Rectangle()
                                        .fill(PPColor.cyan)
                                        .frame(width: 2)
                                        .padding(.vertical, PPSpacing.xSmall)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(hasActiveTask)
                        .accessibilityLabel(
                            isOpening
                                ? AppLocalization.format(
                                    "Opening version %@",
                                    milestone.displayTitle
                                )
                                : milestoneAccessibilityLabel(milestone)
                        )
                        .accessibilityHint(
                            (
                                activeTaskDescription
                                    ?? milestoneAccessibilityHint(
                                        milestone
                                    )
                            ).localizedUI
                        )
                        .accessibilityIdentifier(
                            "openLinkedMilestone-\(milestone.id.uuidString)"
                        )

                        if index < displayedLinkedMilestones.count - 1 {
                            Rectangle()
                                .fill(PPColor.border.opacity(0.54))
                                .frame(height: 0.6)
                                .padding(.leading, 36)
                        }
                    }

                    if linkedMilestones.count > 4 {
                        Button {
                            milestoneNavigationFeedback += 1
                            withAnimation(
                                reduceMotion
                                    ? nil
                                    : .snappy(duration: 0.2)
                            ) {
                                showsAllLinkedMilestones.toggle()
                            }
                        } label: {
                            Label(
                                linkedMilestoneExpansionTitle,
                                systemImage: showsAllLinkedMilestones
                                    ? "chevron.up"
                                    : "chevron.down"
                            )
                            .font(.caption.weight(.semibold))
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(.vertical, PPSpacing.small)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PPColor.cyan)
                        .disabled(hasActiveTask)
                        .accessibilityHint(
                            (
                                activeTaskDescription
                                    ?? (
                                        showsAllLinkedMilestones
                                            ? "Collapses the linked milestone list."
                                            : "Shows remaining linked milestones in this receipt."
                                    )
                            ).localizedUI
                        )
                        .accessibilityIdentifier(
                            "toggleAllReceiptMilestones"
                        )
                    }
                }
            } else if let milestoneEvidenceErrorMessage {
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    Label(
                        milestoneEvidenceErrorMessage.localizedUI,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .fixedSize(horizontal: false, vertical: true)

                    Button {
                        milestoneEvidenceReloadRequest &+= 1
                    } label: {
                        Label(
                            "Retry version evidence",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.cyan)
                    )
                    .disabled(hasActiveTask)
                    .accessibilityIdentifier(
                        "retryReceiptMilestoneEvidence"
                    )
                }
            } else if !canReadProtectedEvidence {
                Label(
                    "Version evidence paused".localizedUI,
                    systemImage: "pause.circle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .frame(minHeight: 44)
            } else {
                HStack(spacing: PPSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking version evidence".localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                }
                .frame(minHeight: 44)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    @ViewBuilder
    private func milestoneProtectionRow(
        record: DocumentRecord,
        availability: PDFDeliveryMilestoneAvailability
    ) -> some View {
        if availability == .protectCurrent
            || availability == .protectRecovery {
            Button {
                protectDeliveryMilestone()
            } label: {
                HStack(spacing: PPSpacing.medium) {
                    Image(
                        systemName: availability == .protectCurrent
                            ? "pin.circle"
                            : "clock.badge.checkmark"
                    )
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PPColor.mint)
                    .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            (
                                availability == .protectCurrent
                                    ? "Protect verified version"
                                    : "Protect matching recovery version"
                            ).localizedUI
                        )
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        Text(
                            (
                                availability == .protectCurrent
                                    ? "Keep the exact checked PDF outside automatic version rotation."
                                    : "The working copy changed. Preserve the recovery version that matches this receipt."
                            ).localizedUI
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(
                            AppLocalization.format(
                                "%@ · Counts toward milestone storage",
                                milestoneStorageSize(record: record)
                            )
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(
                            canProtectMilestone(record: record)
                                ? PPColor.textSecondary
                                : PPColor.rose
                        )
                        if !canProtectMilestone(record: record) {
                            Text(
                                "Milestone storage is full. Unpin or archive an older milestone first."
                                    .localizedUI
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PPColor.rose)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                        }
                    }

                    Spacer(minLength: PPSpacing.small)

                    if milestoneProtectionTask != nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "pin.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PPColor.mint)
                    }
                }
                .padding(.vertical, PPSpacing.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                hasActiveTask
                    || !canProtectMilestone(record: record)
            )
            .accessibilityLabel(
                (
                    availability == .protectCurrent
                        ? "Protect verified version"
                        : "Protect matching recovery version"
                ).localizedUI
            )
            .accessibilityHint(
                (
                    activeTaskDescription
                        ?? (
                            canProtectMilestone(record: record)
                        ? "Keeps an exact local version linked to this receipt."
                        : "Unpin or archive an older milestone first."
                        )
                ).localizedUI
            )
            .accessibilityIdentifier("protectDeliveryMilestone")
        } else {
            HStack(alignment: .top, spacing: PPSpacing.medium) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        (receiptOverride == nil
                            ? "Matching version unavailable"
                            : "Protected receipt link unavailable").localizedUI
                    )
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(
                        (receiptOverride == nil
                            ? "The receipt remains, but its exact PDF version is no longer in local history."
                            : "No protected version remains linked to this archived receipt.").localizedUI
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, PPSpacing.small)
            .accessibilityElement(children: .combine)
        }
    }

    private func milestoneStorageSize(
        record: DocumentRecord
    ) -> String {
        let bytes = milestoneEvidence?
            .matchingUnlinkedMilestone?
            .byteCount ?? record.profile.byteCount
        return ByteCountFormatter.string(
            fromByteCount: max(0, bytes),
            countStyle: .file
        )
    }

    private func canProtectMilestone(
        record: DocumentRecord
    ) -> Bool {
        guard let milestoneEvidence else { return false }
        if milestoneEvidence.availability == .linked {
            return true
        }
        if milestoneEvidence.matchingUnlinkedMilestone?
            .isPinnedMilestone == true {
            return true
        }
        let bytes = milestoneEvidence
            .matchingUnlinkedMilestone?
            .byteCount ?? record.profile.byteCount
        return milestoneEvidence.pinnedStorageSummary.canAdd(
            bytes: bytes
        )
    }

    private var milestoneEvidenceDetail: String {
        if !canReadProtectedEvidence {
            return "Version evidence paused".localizedUI
        }
        if milestoneEvidenceErrorMessage != nil {
            return "Version evidence unavailable".localizedUI
        }
        guard let milestoneEvidence else {
            return "Checking protected revisions".localizedUI
        }
        switch milestoneEvidence.availability {
        case .linked:
            return "Protected revisions tied to this receipt".localizedUI
        case .protectCurrent:
            return "Keep this checked state beyond automatic rotation"
                .localizedUI
        case .protectRecovery:
            return "A matching recovery version is ready to protect"
                .localizedUI
        case .unavailable:
            return (receiptOverride == nil
                ? "No exact local version matches this receipt"
                : "Protected receipt link unavailable").localizedUI
        }
    }

    private func loadMilestoneEvidence() async {
        guard canReadProtectedEvidence, !Task.isCancelled else { return }
        guard let receipt = displayedReceipt
        else {
            milestoneEvidence = .unavailable
            return
        }
        let receiptID = receipt.id
        let generation = milestoneEvidenceGeneration
        let requestID = milestoneEvidenceTaskID
        let loaded = await model.deliveryMilestoneEvidence(
            recordID: recordID,
            receiptID: receiptID,
            retainedReceipt: receiptOverride
        )
        guard !Task.isCancelled,
              milestoneEvidenceGeneration == generation,
              milestoneEvidenceTaskID == requestID,
              canReadProtectedEvidence,
              displayedReceipt?.id == receiptID
        else { return }
        guard let loaded else {
            milestoneEvidenceErrorMessage =
                "Version evidence could not be checked. Try again."
            milestoneEvidenceErrorFeedback += 1
            return
        }
        milestoneEvidenceErrorMessage = nil
        milestoneEvidence = loaded
    }

    private var linkedMilestoneExpansionTitle: String {
        if showsAllLinkedMilestones {
            return "Show fewer linked milestones".localizedUI
        }
        return AppLocalization.format(
            "Show %lld more linked milestones",
            linkedMilestones.count - 4
        )
    }

    private func isReturningToPresentedVersion(
        _ milestone: PDFVersionSnapshot
    ) -> Bool {
        linkedMilestoneOverride?.id == milestone.id
    }

    private func milestoneActionTitle(
        _ milestone: PDFVersionSnapshot
    ) -> String {
        isReturningToPresentedVersion(milestone)
            ? "RETURN TO VERSION"
            : "OPEN VERSION"
    }

    private func milestoneAccessibilityLabel(
        _ milestone: PDFVersionSnapshot
    ) -> String {
        AppLocalization.format(
            isReturningToPresentedVersion(milestone)
                ? "Return to version %@"
                : "Open version %@",
            milestone.displayTitle
        )
    }

    private func milestoneAccessibilityHint(
        _ milestone: PDFVersionSnapshot
    ) -> String {
        isReturningToPresentedVersion(milestone)
            ? "Returns to the version history already open behind this receipt."
            : "Opens this protected version."
    }

    private func openLinkedMilestone(
        _ milestone: PDFVersionSnapshot
    ) {
        guard !hasActiveTask else { return }
        milestoneNavigationFeedback += 1
        if isReturningToPresentedVersion(milestone) {
            dismiss()
        } else {
            selectedMilestone = milestone
        }
    }

    private func protectDeliveryMilestone() {
        guard !hasActiveTask else { return }
        let generation = UUID()
        milestoneProtectionGeneration = generation
        milestoneProtectionStopRequested = false
        milestoneProtectionTask = Task { @MainActor in
            let protected = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.protectDeliveryReceiptMilestone(
                    recordID: recordID
                )
            }
            guard milestoneProtectionGeneration == generation else {
                return
            }
            if protected != nil {
                milestoneEvidenceGeneration = UUID()
                await loadMilestoneEvidence()
                guard milestoneProtectionGeneration == generation else {
                    return
                }
                protectedMilestoneCount += 1
            }
            let wasStopped =
                milestoneProtectionStopRequested || Task.isCancelled
            milestoneProtectionTask = nil
            milestoneProtectionStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    protected == nil
                        ? "Milestone protection stopped"
                        : "Milestone protection finished before stopping · version kept"
                ).localizedUI
            }
        }
    }

    private var hasActiveTask: Bool {
        recheckTask != nil
            || milestoneProtectionTask != nil
            || sharePreparationTask != nil
            || milestoneNavigationTask != nil
            || unlockContinuationTask != nil
            || pendingMilestonePageOpen != nil
    }

    private var hasRequestedTaskStop: Bool {
        recheckStopRequested || milestoneProtectionStopRequested
    }

    private var activeTaskDescription: String? {
        if hasRequestedTaskStop {
            return "Finishing the current protected commit."
        }
        if recheckTask != nil {
            return "Wait for PDF verification to finish."
        }
        if milestoneProtectionTask != nil {
            return "Wait for milestone protection to finish."
        }
        if preparingShareArtifactKind == .pdf {
            return "Wait for the protected share copy to finish."
        }
        if preparingShareArtifactKind == .deliveryPackage {
            return "Wait for the delivery package to finish."
        }
        if preparingShareArtifactKind == .changeReport {
            return "Wait for the change report to finish."
        }
        if milestoneNavigationTask != nil
            || pendingMilestonePageOpen != nil {
            return "Wait for the selected version page to open."
        }
        return nil
    }

    private func stopActiveTask() {
        if sharePreparationTask != nil {
            stopSharePreparation()
        } else if milestoneProtectionTask != nil {
            guard !milestoneProtectionStopRequested else { return }
            milestoneProtectionStopRequested = true
            milestoneProtectionTask?.cancel()
        } else if milestoneNavigationTask != nil
                    || pendingMilestonePageOpen != nil {
            stopMilestoneNavigation()
        } else if unlockContinuationTask != nil {
            unlockContinuationTask?.cancel()
            unlockContinuationTask = nil
            resumesRecheckAfterUnlock = false
        } else if recheckTask != nil {
            guard !recheckStopRequested else { return }
            recheckStopRequested = true
            recheckTask?.cancel()
        }
    }

    private func invalidatePersistentReceiptTasks() {
        recheckGeneration = UUID()
        recheckStopRequested = false
        recheckTask?.cancel()
        recheckTask = nil
        milestoneProtectionGeneration = UUID()
        milestoneProtectionStopRequested = false
        milestoneProtectionTask?.cancel()
        milestoneProtectionTask = nil
    }

    private func interruptProtectedReceiptWork() {
        milestoneEvidenceGeneration = UUID()
        milestoneEvidence = nil
        milestoneEvidenceErrorMessage = nil
        stopMilestoneNavigation()
        unlockContinuationTask?.cancel()
        unlockContinuationTask = nil
        resumesRecheckAfterUnlock = false
        fingerprintCopy.reset()
        invalidatePersistentReceiptTasks()
        stopSharePreparation()
        isSharing = false
        cleanupPreparedShare()
    }

    private func completeVerifiedOutputUnlock() {
        guard resumesRecheckAfterUnlock else { return }
        resumesRecheckAfterUnlock = false
        guard purchase.isUnlocked else { return }
        unlockContinuationTask?.cancel()
        unlockContinuationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  let record = model.record(id: recordID)
            else {
                unlockContinuationTask = nil
                return
            }
            unlockContinuationTask = nil
            recheck(record)
        }
    }

    private func stopMilestoneNavigation() {
        milestoneNavigationGeneration = UUID()
        milestoneNavigationTask?.cancel()
        milestoneNavigationTask = nil
        pendingMilestonePageOpen = nil
    }

    private func completeMilestonePageOpen() {
        guard let request = pendingMilestonePageOpen else {
            return
        }
        pendingMilestonePageOpen = nil
        milestoneNavigationTask?.cancel()
        let generation = UUID()
        milestoneNavigationGeneration = generation
        milestoneNavigationTask = Task { @MainActor in
            defer {
                if milestoneNavigationGeneration == generation {
                    milestoneNavigationTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  milestoneNavigationGeneration == generation,
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
            milestoneNavigationFeedback += 1
            requestOpenPage(
                recordID: request.recordID,
                pageIndex: request.pageIndex,
                contentRevisionID: request.contentRevisionID
            )
        }
    }

    private func stopSharePreparation() {
        sharePreparationGeneration = UUID()
        sharePreparationTask?.cancel()
        sharePreparationTask = nil
        preparingShareArtifactKind = nil
        pdfShareProgress = nil
        pdfShareRateWindow.reset()
    }

    private func metrics(_ receipt: PDFDeliveryReceipt) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "DELIVERY FACTS")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    fact(
                        "\(receipt.outputPageCount)",
                        label: "PAGES"
                    )
                    metricDivider
                    fact(
                        "\(receipt.renderedPageCount)",
                        label: "RENDERED"
                    )
                    metricDivider
                    fact(
                        receipt.formattedOutputSize,
                        label: "FILE"
                    )
                }

                VStack(spacing: PPSpacing.medium) {
                    HStack(spacing: 0) {
                        fact(
                            "\(receipt.outputPageCount)",
                            label: "PAGES"
                        )
                        metricDivider
                        fact(
                            "\(receipt.renderedPageCount)",
                            label: "RENDERED"
                        )
                    }
                    fact(
                        receipt.formattedOutputSize,
                        label: "FILE"
                    )
                }
            }
            .padding(.vertical, PPSpacing.medium)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PPColor.border.opacity(0.62), lineWidth: 0.7)
            }
        }
    }

    private func fact(_ value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold))
                .fontDesign(.serif)
                .monospacedDigit()
                .foregroundStyle(PPColor.textPrimary)
            Text(label.localizedUI)
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(PPColor.border.opacity(0.62))
            .frame(width: 0.6, height: 42)
    }

    private func checks(_ receipt: PDFDeliveryReceipt) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "CHECKS PERFORMED")
            VStack(spacing: 0) {
                ForEach(
                    Array(receipt.checks.enumerated()),
                    id: \.element.id
                ) { index, check in
                    checkRow(check)
                    if index < receipt.checks.count - 1 {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.55))
                            .frame(height: 0.6)
                            .padding(.leading, 36)
                    }
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.68))
                    .frame(height: 0.7)
            }
        }
    }

    private func checkRow(_ check: PDFDeliveryCheck) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            Image(systemName: checkSymbol(check.status))
                .font(.body.weight(.semibold))
                .foregroundStyle(checkColor(check.status))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(check.title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(check.detail.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PPSpacing.medium)
        .accessibilityElement(children: .combine)
    }

    private func fingerprint(_ receipt: PDFDeliveryReceipt) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    SectionEyebrow(
                        text: "SHA-256 FILE FINGERPRINT"
                    )
                    Spacer(minLength: PPSpacing.small)
                    fingerprintCopyButton(receipt)
                }

                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    SectionEyebrow(
                        text: "SHA-256 FILE FINGERPRINT"
                    )
                    fingerprintCopyButton(receipt)
                }
            }

            Text(receipt.sha256.uppercased())
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(PPColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(PPSpacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PPColor.surfaceMuted)
                .clipShape(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .accessibilityLabel(
                    AppLocalization.format(
                        "SHA-256 fingerprint %@",
                        receipt.sha256
                    )
                )

            SecureFingerprintCopyStatusLabel(
                status: fingerprintCopy.status
            )
            .font(.caption.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fingerprintCopyButton(
        _ receipt: PDFDeliveryReceipt
    ) -> some View {
        Button {
            fingerprintCopy.copy(receipt.sha256)
        } label: {
            Label(
                fingerprintCopy.status
                    .fingerprintActionTitle.localizedUI,
                systemImage:
                    fingerprintCopy.status.fingerprintActionSymbol
            )
            .frame(minHeight: 44)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(
            fingerprintCopy.status.fingerprintTint
        )
        .accessibilityLabel(
            fingerprintCopy.status
                .fingerprintActionTitle.localizedUI
        )
        .accessibilityHint(fingerprintCopyAccessibilityHint)
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "SCOPE")
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 112, maximum: 220),
                        spacing: PPSpacing.small
                    )
                ],
                alignment: .leading,
                spacing: PPSpacing.small
            ) {
                scopeToken("Reopen", symbol: "doc.viewfinder", tint: PPColor.mint)
                scopeToken("Page count", symbol: "number", tint: PPColor.mint)
                scopeToken("Rendered pages", symbol: "rectangle.stack", tint: PPColor.mint)
                scopeToken("Visible drift", symbol: "eye", tint: PPColor.cyan)
                scopeToken("Metadata", symbol: "person.crop.circle.badge.xmark", tint: PPColor.accent)
                scopeToken("SHA-256", symbol: "number.square", tint: PPColor.accent)
            }

            HStack(spacing: PPSpacing.small) {
                Image(systemName: "seal")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                Text("Not PDF/A · PDF/UA · PDF/X · digital signature · legal certification")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .padding(.top, PPSpacing.small)
    }

    private func scopeToken(
        _ title: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 15)
            Text(title.localizedUI)
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PPSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 28)
        .background(tint.opacity(0.06))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.34))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func checkSymbol(
        _ status: PDFDeliveryCheckStatus
    ) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .notApplicable: return "minus.circle"
        }
    }

    private func checkColor(
        _ status: PDFDeliveryCheckStatus
    ) -> Color {
        switch status {
        case .passed: return PPColor.mint
        case .warning: return PPColor.amber
        case .failed: return Color.red
        case .notApplicable: return PPColor.textSecondary
        }
    }
}

struct CompareVersionsView: View {
    private struct ComparisonRevisionStamp: Equatable {
        let sourceRevisionID: UUID?
        let revisedRecordID: UUID?
        let revisedRevisionID: UUID?
    }

    private struct ComparisonProofPayload: Identifiable {
        let sourceRecordID: UUID
        let sourceRevisionID: UUID
        let sourceTitle: String
        let sourceURL: URL
        let sourcePageCount: Int
        let sourceRefreshToken: Int
        let revisedRecordID: UUID
        let revisedRevisionID: UUID
        let revisedTitle: String
        let revisedURL: URL
        let revisedPageCount: Int
        let revisedRefreshToken: Int
        let initialSourcePageIndex: Int?
        let initialRevisedPageIndex: Int?
        let initialChangeIndex: Int?
        let review: PDFChangeReview

        var id: String {
            [
                sourceRecordID.uuidString,
                sourceRevisionID.uuidString,
                revisedRecordID.uuidString,
                revisedRevisionID.uuidString
            ].joined(separator: ":")
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    let sourceRecordID: UUID
    let initialRevisedRecordID: UUID?
    let expectedSourceRevisionID: UUID?
    let expectedRevisedRevisionID: UUID?
    let startsComparisonAutomatically: Bool
    let onOpenRoute: (DocumentRoute) -> Void

    @State private var revisedRecordID: UUID?
    @State private var didApplyInitialRoute = false
    @State private var review: PDFChangeReview?
    @State private var errorMessage: String?
    @State private var isComparing = false
    @State private var comparisonTask: Task<Void, Never>?
    @State private var comparisonGeneration = 0
    @State private var comparisonProgress =
        PDFComparisonProgress.starting
    @State private var changeReportTask: Task<Void, Never>?
    @State private var changeReportGeneration = UUID()
    @State private var changeReportURL: URL?
    @State private var isSharingChangeReport = false
    @State private var changeReportShareCount = 0
    @State private var comparisonProof: ComparisonProofPayload?
    @State private var focusedChangeID: String?
    @State private var comparisonSourceRevisionID: UUID?
    @State private var comparisonRevisedRevisionID: UUID?

    init(
        sourceRecordID: UUID,
        initialRevisedRecordID: UUID? = nil,
        expectedSourceRevisionID: UUID? = nil,
        expectedRevisedRevisionID: UUID? = nil,
        startsComparisonAutomatically: Bool = false,
        onOpenRoute: @escaping (DocumentRoute) -> Void
    ) {
        self.sourceRecordID = sourceRecordID
        self.initialRevisedRecordID = initialRevisedRecordID
        self.expectedSourceRevisionID =
            expectedSourceRevisionID
        self.expectedRevisedRevisionID =
            expectedRevisedRevisionID
        self.startsComparisonAutomatically =
            startsComparisonAutomatically
        self.onOpenRoute = onOpenRoute
        _revisedRecordID = State(
            initialValue: initialRevisedRecordID
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if let source = model.record(id: sourceRecordID) {
                    ScrollView {
                        VStack(
                            alignment: .leading,
                            spacing: PPSpacing.large
                        ) {
                            intro(source)
                            comparisonInputs(source: source)
                            if let revisedRecordID {
                                LinkedChangeReportSection(
                                    lookup: .documentPair(
                                        sourceRecordID: source.id,
                                        revisedRecordID:
                                            revisedRecordID
                                    )
                                )
                            }
                            compareAction

                            if isComparing {
                                processing
                            } else if let review {
                                PDFChangeReviewSummary(
                                    review: review,
                                    context: .comparison,
                                    isExportingReport:
                                        changeReportTask != nil,
                                    focusedChangeID: focusedChangeID,
                                    onOpenChange: { change in
                                        focusedChangeID = change.id
                                        guard let revisedRecordID else {
                                            return
                                        }
                                        guard let pageIndex =
                                            change.preferredOpenPageIndex,
                                              let sourceRevisionID =
                                                comparisonSourceRevisionID,
                                              let revisedRevisionID =
                                                comparisonRevisedRevisionID
                                        else {
                                            invalidateComparisonEvidenceForRevisionChange()
                                            return
                                        }
                                        let opensRevised =
                                            change.preferredOpenSide
                                                == .revised
                                        onOpenRoute(
                                            DocumentRoute(
                                                recordID: opensRevised
                                                    ? revisedRecordID
                                                    : sourceRecordID,
                                                pageIndex: pageIndex,
                                                expectedContentRevisionID:
                                                    opensRevised
                                                        ? revisedRevisionID
                                                        : sourceRevisionID
                                            )
                                        )
                                    },
                                    onOpenProof: {
                                        openComparisonProof(
                                            review: review,
                                            source: source
                                        )
                                    },
                                    onExportReport: {
                                        prepareChangeReport(
                                            review: review,
                                            source: source
                                        )
                                    }
                                )
                            } else if let errorMessage {
                                PPEmptyState(
                                    kind: .search,
                                    title: "Comparison unavailable",
                                    message: errorMessage.localizedUI
                                )
                            }
                        }
                        .frame(maxWidth: 1_080)
                        .padding(PPSpacing.regular)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView(
                        "Document unavailable",
                        systemImage: "doc.questionmark"
                    )
                }
            }
            .navigationTitle("Compare Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        (
                            isComparing || changeReportTask != nil
                                ? "Stop"
                                : "Done"
                        ).localizedUI
                    ) {
                        closeOrStopComparison()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .task {
            guard !didApplyInitialRoute else { return }
            didApplyInitialRoute = true
            let initialCandidate = initialRevisedRecordID.flatMap {
                candidateID in
                candidates.first(where: { $0.id == candidateID })
            }
            if revisedRecordID == nil
                || initialCandidate == nil {
                revisedRecordID = candidates.first?.id
            }
            guard startsComparisonAutomatically,
                  let initialCandidate,
                  revisedRecordID == initialCandidate.id,
                  let expectedSourceRevisionID,
                  let expectedRevisedRevisionID,
                  model.record(id: sourceRecordID)?
                    .contentRevisionID == expectedSourceRevisionID,
                  initialCandidate.contentRevisionID
                    == expectedRevisedRevisionID
            else {
                if startsComparisonAutomatically {
                    errorMessage =
                        "The linked PDFs changed after the report was verified."
                }
                return
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            startComparison()
        }
        .onChange(of: revisedRecordID) {
            stopComparison()
            review = nil
            comparisonSourceRevisionID = nil
            comparisonRevisedRevisionID = nil
            focusedChangeID = nil
            comparisonProof = nil
            errorMessage = nil
        }
        .onChange(of: comparisonRevisionStamp) {
            oldStamp,
            newStamp in
            guard oldStamp.revisedRecordID
                    == newStamp.revisedRecordID,
                  oldStamp.sourceRevisionID
                    != newStamp.sourceRevisionID
                    || oldStamp.revisedRevisionID
                        != newStamp.revisedRevisionID
            else { return }
            invalidateComparisonEvidenceForRevisionChange()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptProtectedComparison()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtectedComparison()
        }
        .onDisappear {
            stopComparison()
            stopChangeReportPreparation()
        }
        .accessibilityAction(.escape) {
            closeOrStopComparison()
        }
        .sheet(
            isPresented: $isSharingChangeReport,
            onDismiss: cleanupChangeReport
        ) {
            if let changeReportURL {
                ShareSheet(items: [changeReportURL])
            }
        }
        .fullScreenCover(item: $comparisonProof) { payload in
            PDFComparisonProofView(
                configuration: PDFComparisonProofConfiguration(
                    id: "documents:\(payload.id)",
                    navigationTitle: "Comparison proof",
                    evidenceLabel: "COMPARISON EVIDENCE",
                    sourceLabel: "BASE",
                    sourceTitle: payload.sourceTitle,
                    sourceURL: payload.sourceURL,
                    sourcePageCount: payload.sourcePageCount,
                    sourceRefreshToken:
                        payload.sourceRefreshToken,
                    sourceSymbol: "doc",
                    revisedLabel: "REVISED",
                    revisedTitle: payload.revisedTitle,
                    revisedURL: payload.revisedURL,
                    revisedPageCount: payload.revisedPageCount,
                    revisedRefreshToken:
                        payload.revisedRefreshToken,
                    revisedSymbol: "doc.fill",
                    initialSourcePageIndex:
                        payload.initialSourcePageIndex,
                    initialRevisedPageIndex:
                        payload.initialRevisedPageIndex,
                    initialChangeIndex:
                        payload.initialChangeIndex,
                    recompute: { manualMatches, progress in
                        guard model.record(
                            id: payload.sourceRecordID
                        )?.contentRevisionID
                            == payload.sourceRevisionID,
                              model.record(
                                id: payload.revisedRecordID
                              )?.contentRevisionID
                                == payload.revisedRevisionID
                        else {
                            throw PaperPathError
                                .outputVerificationFailed(
                                    "a compared PDF changed during page-pair review"
                                )
                        }
                        return try await model.comparePDFs(
                            sourceRecordID:
                                payload.sourceRecordID,
                            revisedRecordID:
                                payload.revisedRecordID,
                            manualMatches: manualMatches,
                            progress: progress
                        )
                    }
                ),
                review: payload.review
            ) { updatedReview in
                acceptProofReview(updatedReview, payload: payload)
            }
        }
        .sensoryFeedback(
            .success,
            trigger: review?.totalChangedPageCount
        )
        .sensoryFeedback(.selection, trigger: focusedChangeID)
        .sensoryFeedback(
            .success,
            trigger: changeReportShareCount
        )
    }

    private func intro(
        _ source: DocumentRecord
    ) -> some View {
        WorkflowCommandHeader(
            eyebrow: "LOCAL CHANGE REVIEW",
            title: "Compare versions",
            detail: "Compare visible pixels, text, page count, and geometry on this device.",
            symbol: "doc.on.doc",
            tint: PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(source.profile.pageCount)",
                    label: "Base pages",
                    symbol: "doc",
                    tint: PPColor.textSecondary
                ),
                WorkflowMetric(
                    value: revisedRecord.map {
                        "\($0.profile.pageCount)"
                    } ?? "—",
                    label: "Revised pages",
                    symbol: "doc.fill",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: "\(candidates.count)",
                    label: "Candidates",
                    symbol: "square.stack.3d.up",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: review.map {
                        "\($0.totalChangedPageCount)"
                    } ?? "Not run",
                    label: "Changed",
                    symbol: "doc.text.magnifyingglass",
                    tint: review?.isIdentical == true
                        ? PPColor.mint
                        : PPColor.amber
                )
            ]
        )
    }

    @ViewBuilder
    private func comparisonInputs(
        source: DocumentRecord
    ) -> some View {
        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: PPSpacing.large) {
                comparisonDocumentRow(
                    label: "BASE PDF",
                    record: source,
                    tint: PPColor.textSecondary
                )
                .frame(maxWidth: .infinity)
                revisedSelection
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                comparisonDocumentRow(
                    label: "BASE PDF",
                    record: source,
                    tint: PPColor.textSecondary
                )
                Rectangle()
                    .fill(PPColor.border.opacity(0.6))
                    .frame(height: 0.7)
                    .padding(.leading, 68)
                revisedSelection
            }
        }
    }

    @ViewBuilder
    private var revisedSelection: some View {
        if let revised = revisedRecord {
            Menu {
                ForEach(candidates) { candidate in
                    Button {
                        revisedRecordID = candidate.id
                    } label: {
                        Label(
                            candidate.displayName,
                            systemImage: candidate.id == revised.id
                                ? "checkmark.circle.fill"
                                : "doc"
                        )
                    }
                }
            } label: {
                comparisonDocumentRow(
                    label: "COMPARE WITH",
                    record: revised,
                    tint: PPColor.cyan,
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: PPSpacing.medium) {
                Image(systemName: "doc.badge.questionmark")
                    .foregroundStyle(PPColor.amber)
                    .frame(width: 44, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text("COMPARE WITH")
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                    Text("Import another unlocked PDF first")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                }
                Spacer()
            }
            .padding(PPSpacing.medium)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
        }
    }

    private func comparisonDocumentRow(
        label: String,
        record: DocumentRecord,
        tint: Color,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(spacing: PPSpacing.medium) {
            if let url = model.url(for: record.id) {
                PDFPageThumbnailView(
                    url: url,
                    pageIndex: 0,
                    refreshToken: model.refreshToken(for: record.id),
                    width: 42
                )
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 54)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label.localizedUI)
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(tint)
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? nil
                            : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "\(record.profile.pageCount) page\(record.profile.pageCount == 1 ? "" : "s") · \(record.profile.formattedSize)"
                )
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(PPColor.textSecondary)
            }
            Spacer(minLength: PPSpacing.small)
            if showsDisclosure {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .padding(PPSpacing.medium)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var compareAction: some View {
        Button {
            startComparison()
        } label: {
            Label(
                isComparing ? "Comparing on device" : "Compare PDFs",
                systemImage: isComparing
                    ? "hourglass"
                    : "doc.text.magnifyingglass"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(revisedRecordID == nil || isComparing)
        .accessibilityIdentifier("compareVersionsButton")
    }

    private var processing: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.medium) {
                LocalComparisonProgressView(
                    progress: comparisonProgress
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    stopComparison()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.cyan)
                .accessibilityLabel("Stop comparison".localizedUI)
            }
            Text("Visible content, text layer, and geometry".localizedUI)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
        }
        .padding(PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var candidates: [DocumentRecord] {
        DocumentComparisonCandidates.ordered(
            from: model.documents,
            sourceID: sourceRecordID
        )
    }

    private var revisedRecord: DocumentRecord? {
        guard let revisedRecordID else { return nil }
        return model.record(id: revisedRecordID)
    }

    private var comparisonRevisionStamp:
        ComparisonRevisionStamp {
        ComparisonRevisionStamp(
            sourceRevisionID: model.record(
                id: sourceRecordID
            )?.contentRevisionID,
            revisedRecordID: revisedRecordID,
            revisedRevisionID: revisedRecordID.flatMap {
                model.record(id: $0)?.contentRevisionID
            }
        )
    }

    private func startComparison() {
        guard let revisedRecordID,
              let source = model.record(id: sourceRecordID),
              let revised = model.record(id: revisedRecordID)
        else { return }
        guard scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else {
            errorMessage =
                "Comparison stopped to protect your documents. Start it again when PaperPath is active."
            return
        }
        stopComparison()
        comparisonGeneration &+= 1
        let generation = comparisonGeneration
        let sourceRevisionID = source.contentRevisionID
        let revisedRevisionID = revised.contentRevisionID
        review = nil
        comparisonSourceRevisionID = nil
        comparisonRevisedRevisionID = nil
        focusedChangeID = nil
        comparisonProof = nil
        errorMessage = nil
        isComparing = true
        comparisonProgress = .starting
        comparisonTask = Task {
            defer {
                if generation == comparisonGeneration {
                    isComparing = false
                    comparisonTask = nil
                    comparisonProgress = .starting
                }
            }
            do {
                let result = try await model.comparePDFs(
                    sourceRecordID: sourceRecordID,
                    revisedRecordID: revisedRecordID
                ) { update in
                    guard generation == comparisonGeneration,
                          update.fractionCompleted
                            >= comparisonProgress.fractionCompleted
                    else { return }
                    comparisonProgress = update
                }
                try Task.checkCancellation()
                guard generation == comparisonGeneration,
                      model.record(id: sourceRecordID)?
                        .contentRevisionID == sourceRevisionID,
                      model.record(id: revisedRecordID)?
                        .contentRevisionID == revisedRevisionID
                else {
                    invalidateComparisonEvidenceForRevisionChange()
                    return
                }
                review = result
                comparisonSourceRevisionID = sourceRevisionID
                comparisonRevisedRevisionID = revisedRevisionID
            } catch is CancellationError {
                return
            } catch {
                guard generation == comparisonGeneration else {
                    return
                }
                errorMessage = AppLocalization
                    .userFacingErrorDescription(error)
            }
        }
    }

    private func stopComparison() {
        comparisonGeneration &+= 1
        comparisonTask?.cancel()
        comparisonTask = nil
        isComparing = false
        comparisonProgress = .starting
    }

    private func closeOrStopComparison() {
        if isComparing {
            stopComparison()
        } else if changeReportTask != nil {
            stopChangeReportPreparation()
        } else {
            dismiss()
        }
    }

    private func interruptProtectedComparison() {
        let hadEvidence = isComparing
            || review != nil
            || comparisonProof != nil
            || changeReportTask != nil
        stopComparison()
        stopChangeReportPreparation()
        comparisonProof = nil
        review = nil
        comparisonSourceRevisionID = nil
        comparisonRevisedRevisionID = nil
        focusedChangeID = nil
        guard hadEvidence else { return }
        errorMessage =
            "Comparison stopped to protect your documents. Start it again when PaperPath is active."
    }

    private func invalidateComparisonEvidenceForRevisionChange() {
        let hadEvidence = review != nil
            || comparisonProof != nil
            || isComparing
            || changeReportTask != nil
        stopComparison()
        comparisonProof = nil
        review = nil
        comparisonSourceRevisionID = nil
        comparisonRevisedRevisionID = nil
        focusedChangeID = nil
        stopChangeReportPreparation()
        guard hadEvidence else { return }
        errorMessage =
            "A compared PDF changed. Compare again before reviewing or exporting evidence."
    }

    private func openComparisonProof(
        review: PDFChangeReview,
        source: DocumentRecord
    ) {
        guard let revised = revisedRecord,
              source.contentRevisionID
                == comparisonSourceRevisionID,
              revised.contentRevisionID
                == comparisonRevisedRevisionID,
              let sourceURL = model.url(for: source.id),
              let revisedURL = model.url(for: revised.id)
        else {
            errorMessage =
                "One of the compared PDFs is no longer available."
            return
        }
        let focusedChange = preferredProofChange(in: review)
        focusedChangeID = focusedChange?.id
        let initialChangeIndex = focusedChange.flatMap {
            change in
            review.changes.firstIndex { $0.id == change.id }
        }
        comparisonProof = ComparisonProofPayload(
            sourceRecordID: source.id,
            sourceRevisionID: source.contentRevisionID,
            sourceTitle: source.displayName,
            sourceURL: sourceURL,
            sourcePageCount: source.profile.pageCount,
            sourceRefreshToken: model.refreshToken(for: source.id),
            revisedRecordID: revised.id,
            revisedRevisionID: revised.contentRevisionID,
            revisedTitle: revised.displayName,
            revisedURL: revisedURL,
            revisedPageCount: revised.profile.pageCount,
            revisedRefreshToken: model.refreshToken(for: revised.id),
            initialSourcePageIndex:
                focusedChange?.resolvedSourcePageIndex,
            initialRevisedPageIndex:
                focusedChange?.resolvedRevisedPageIndex,
            initialChangeIndex: initialChangeIndex,
            review: review
        )
    }

    private func preferredProofChange(
        in review: PDFChangeReview
    ) -> PDFPageChange? {
        if let focusedChangeID,
           let focused = review.changes.first(
                where: { $0.id == focusedChangeID }
           ) {
            return focused
        }
        return review.criticalChanges.first
            ?? review.visibleChanges.first
            ?? review.textChanges.first
            ?? review.changes.first
    }

    private func acceptProofReview(
        _ updatedReview: PDFChangeReview,
        payload: ComparisonProofPayload
    ) {
        guard model.record(
            id: payload.sourceRecordID
        )?.contentRevisionID == payload.sourceRevisionID,
              model.record(
                id: payload.revisedRecordID
              )?.contentRevisionID == payload.revisedRevisionID
        else {
            comparisonProof = nil
            invalidateComparisonEvidenceForRevisionChange()
            return
        }

        let previousFocusedChangeID = focusedChangeID
        review = updatedReview
        comparisonSourceRevisionID = payload.sourceRevisionID
        comparisonRevisedRevisionID = payload.revisedRevisionID
        if let previousFocusedChangeID,
           updatedReview.changes.contains(
                where: { $0.id == previousFocusedChangeID }
           ) {
            focusedChangeID = previousFocusedChangeID
        } else if let initialChangeIndex = payload.initialChangeIndex,
                  updatedReview.changes.indices
                    .contains(initialChangeIndex) {
            focusedChangeID =
                updatedReview.changes[initialChangeIndex].id
        } else {
            focusedChangeID = updatedReview.changes.first?.id
        }
    }

    private func prepareChangeReport(
        review: PDFChangeReview,
        source: DocumentRecord
    ) {
        guard changeReportTask == nil,
              let revised = revisedRecord
        else { return }
        guard let sourceRevisionID =
                comparisonSourceRevisionID,
              let revisedRevisionID =
                comparisonRevisedRevisionID,
              source.contentRevisionID == sourceRevisionID,
              revised.contentRevisionID == revisedRevisionID
        else {
            invalidateComparisonEvidenceForRevisionChange()
            return
        }
        cleanupChangeReport()
        let generation = UUID()
        changeReportGeneration = generation
        let descriptor = PDFChangeReportDescriptor(
            reportID: UUID(),
            scope: "Working copy comparison".localizedUI,
            sourceName: source.displayName,
            revisedName: revised.displayName,
            sourceRevisionID: sourceRevisionID,
            revisedRevisionID: revisedRevisionID,
            sourceFingerprint: source.contentFingerprint,
            revisedFingerprint: revised.contentFingerprint,
            deliveryReceiptID: nil,
            generatedAt: PDFOfficeTimeAnchor.process.trustedDate()
        )
        changeReportTask = Task { @MainActor in
            let url = await model.makeChangeReport(
                review: review,
                descriptor: descriptor,
                validatingRevisions: [
                    source.id: sourceRevisionID,
                    revised.id: revisedRevisionID
                ],
                localLink: PDFRetainedChangeReportLocalLink
                    .documentPair(
                        source: source,
                        revised: revised
                    )
            )
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

    private func stopChangeReportPreparation() {
        changeReportGeneration = UUID()
        changeReportTask?.cancel()
        changeReportTask = nil
        isSharingChangeReport = false
        cleanupChangeReport()
    }
}

struct LinkedChangeReportSection: View {
    private struct LoadRequest: Hashable {
        let lookup: PDFRetainedChangeReportLookup
        let storageRevision: Int
        let isAvailable: Bool
        let reload: Int
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.scenePhase) private var scenePhase

    let lookup: PDFRetainedChangeReportLookup

    @State private var reports: [PDFRetainedChangeReport] = []
    @State private var loadedLookup: PDFRetainedChangeReportLookup?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadRequest = 0
    @State private var showsAllReports = false
    @State private var protectedDataAvailable =
        UIApplication.shared.isProtectedDataAvailable
    @State private var presentedVerification:
        PDFChangeReportVerificationResult?
    @State private var verificationTask: Task<Void, Never>?
    @State private var verifyingReportID: UUID?
    @State private var failedReportID: UUID?
    @State private var verificationError: String?
    @State private var verificationGeneration = UUID()
    @State private var loadGeneration = UUID()
    @State private var verificationFeedback = 0
    @State private var verificationErrorFeedback = 0

    var body: some View {
        Group {
            if !reports.isEmpty || isLoading || loadError != nil {
                VStack(alignment: .leading, spacing: 0) {
                    StudioSectionRule(
                        title: "RELATED SIGNED REPORT",
                        detail: "Stored locally · reverified on open",
                        symbol: "lock.doc",
                        count: reports.count,
                        tint: PPColor.cyan
                    )
                    if isLoading {
                        ProgressView("Loading linked reports".localizedUI)
                            .font(.caption)
                            .padding(.vertical, PPSpacing.small)
                    }
                    if let loadError {
                        failureStatus(loadError) {
                            reloadRequest &+= 1
                        }
                    }
                    if let verificationError {
                        failureStatus(verificationError) {
                            if let report = reports.first(where: { $0.id == failedReportID }) {
                                open(report)
                            } else {
                                reloadRequest &+= 1
                            }
                        }
                    }
                    ForEach(displayedReports) { report in
                        reportRow(report)
                    }
                    if reports.count > 3 {
                        Button {
                            showsAllReports.toggle()
                        } label: {
                            Label(
                                showsAllReports
                                    ? "Show fewer reports".localizedUI
                                    : AppLocalization.format(
                                        "Show %lld more reports",
                                        reports.count - 3
                                    ),
                                systemImage: showsAllReports ? "chevron.up" : "chevron.down"
                            )
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PPColor.cyan)
                        .accessibilityIdentifier("expandLinkedReports")
                    }
                    if verificationTask != nil {
                        Button(role: .cancel) {
                            cancelVerification()
                        } label: {
                            Label(
                                "Stop report check".localizedUI,
                                systemImage: "stop.circle"
                            )
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PPColor.amber)
                        .accessibilityIdentifier("stopLinkedReportCheck")
                    }
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.62))
                        .frame(height: 0.6)
                }
            }
        }
        .task(id: loadRequest) {
            if loadedLookup != lookup {
                loadedLookup = lookup
                showsAllReports = false
                reports = []
                verificationError = nil
                failedReportID = nil
                presentedVerification = nil
            }
            cancelVerification()
            await loadReports()
        }
        .sheet(
            item: $presentedVerification,
            onDismiss: { reloadRequest &+= 1 }
        ) { report in
            ChangeReportVerificationView(report: report) { candidate in
                let request = loadRequest
                let updated = await model.trustChangeReportSigner(candidate)
                if let updated,
                   presentedVerification?.id == candidate.id,
                   loadRequest == request,
                   canReadReports {
                    presentedVerification = updated
                }
                return updated
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            protectedDataAvailable = false
            interruptReports()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            protectedDataAvailable = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                interruptReports()
            }
        }
        .onDisappear {
            loadGeneration = UUID()
            cancelVerification()
        }
        .sensoryFeedback(.success, trigger: verificationFeedback)
        .sensoryFeedback(.error, trigger: verificationErrorFeedback)
    }

    private var canReadReports: Bool {
        scenePhase == .active
            && protectedDataAvailable
            && UIApplication.shared.isProtectedDataAvailable
    }

    private var loadRequest: LoadRequest {
        LoadRequest(
            lookup: lookup,
            storageRevision: model.retainedEvidenceRevision,
            isAvailable: canReadReports,
            reload: reloadRequest
        )
    }

    private var displayedReports: [PDFRetainedChangeReport] {
        showsAllReports ? reports : Array(reports.prefix(3))
    }

    private func reportRow(_ report: PDFRetainedChangeReport) -> some View {
        Button {
            open(report)
        } label: {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: "doc.text.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(report.sourceName) → \(report.revisedName)")
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        AppLocalization.format(
                            "%@ · %lld changed",
                            report.generatedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            ),
                            report.changedPageCount
                        )
                    )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if verifyingReportID == report.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(PPColor.cyan)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .padding(.vertical, PPSpacing.small)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(verificationTask != nil || isLoading || !canReadReports || loadError != nil)
        .help("Open signed report".localizedUI)
        .hoverEffect(.highlight)
        .accessibilityValue(
            verifyingReportID == report.id ? "Checking report".localizedUI : ""
        )
        .accessibilityHint(
            "Reverifies the saved report before opening it.".localizedUI
        )
        .accessibilityIdentifier("linkedReport-\(report.id.uuidString)")
    }

    private func failureStatus(
        _ message: String,
        retry: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Label(message.localizedUI, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(PPColor.amber)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: retry) {
                Label("Retry".localizedUI, systemImage: "arrow.clockwise")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(isLoading || verificationTask != nil || !canReadReports)
        }
        .padding(.vertical, PPSpacing.small)
    }

    private func loadReports() async {
        guard canReadReports else {
            isLoading = false
            return
        }
        let generation = UUID()
        let request = loadRequest
        loadGeneration = generation
        isLoading = true
        loadError = nil
        defer {
            if loadGeneration == generation { isLoading = false }
        }
        do {
            let loaded = try await model.loadLinkedChangeReports(matching: lookup)
            guard loadGeneration == generation,
                  request == loadRequest,
                  canReadReports,
                  !Task.isCancelled
            else { return }
            reports = loaded
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation,
                  request == loadRequest,
                  canReadReports,
                  !Task.isCancelled
            else { return }
            loadError = "Linked reports could not be loaded. Try again."
        }
    }

    private func open(_ report: PDFRetainedChangeReport) {
        guard verificationTask == nil, !isLoading, canReadReports else { return }
        let generation = UUID()
        let request = loadRequest
        verificationGeneration = generation
        verifyingReportID = report.id
        verificationError = nil
        failedReportID = nil
        verificationTask = Task { @MainActor in
            defer {
                if verificationGeneration == generation {
                    verificationTask = nil
                    verifyingReportID = nil
                }
            }
            do {
                let verification = try await model.checkRetainedChangeReport(id: report.id)
                guard verificationGeneration == generation,
                      request == loadRequest,
                      canReadReports,
                      !Task.isCancelled
                else { return }
                presentedVerification = verification
                if verification.isVerified {
                    verificationFeedback += 1
                } else {
                    verificationErrorFeedback += 1
                }
            } catch is CancellationError {
                return
            } catch {
                guard verificationGeneration == generation,
                      request == loadRequest,
                      canReadReports,
                      !Task.isCancelled
                else { return }
                failedReportID = report.id
                verificationError =
                    "The saved report could not be verified. It has not been opened."
                verificationErrorFeedback += 1
            }
        }
    }

    private func interruptReports() {
        loadGeneration = UUID()
        reports = []
        isLoading = false
        loadError = nil
        verificationError = nil
        failedReportID = nil
        cancelVerification()
        presentedVerification = nil
    }

    private func cancelVerification() {
        verificationGeneration = UUID()
        verificationTask?.cancel()
        verificationTask = nil
        verifyingReportID = nil
    }
}

private struct PDFChangeReviewSummary: View {
    enum Context {
        case delivery
        case comparison
    }

    let review: PDFChangeReview
    let context: Context
    let isExportingReport: Bool
    let focusedChangeID: String?
    let onOpenChange: (PDFPageChange) -> Void
    let onOpenProof: (() -> Void)?
    let onExportReport: (() -> Void)?

    init(
        review: PDFChangeReview,
        context: Context,
        isExportingReport: Bool = false,
        focusedChangeID: String? = nil,
        onOpenChange: @escaping (PDFPageChange) -> Void,
        onOpenProof: (() -> Void)? = nil,
        onExportReport: (() -> Void)? = nil
    ) {
        self.review = review
        self.context = context
        self.isExportingReport = isExportingReport
        self.focusedChangeID = focusedChangeID
        self.onOpenChange = onOpenChange
        self.onOpenProof = onOpenProof
        self.onExportReport = onExportReport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(
                text: context == .delivery
                    ? "CHANGE REVIEW"
                    : "COMPARISON RESULT"
            )
            HStack(alignment: .top, spacing: PPSpacing.medium) {
                Image(systemName: summarySymbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(summaryColor)
                    .frame(width: 34, height: 34)
                    .background(summaryColor.opacity(0.09), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(summaryTitle)
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(summaryDetail)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    reviewFact(
                        "\(visibleChangedPageCount)",
                        label: "VISIBLE"
                    )
                    reviewDivider
                    reviewFact(
                        "\(review.textChangedPageCount)",
                        label: "TEXT PAGES"
                    )
                    reviewDivider
                    reviewFact(
                        "\(textEvidenceCount)",
                        label: "TEXT MARKS"
                    )
                    reviewDivider
                    reviewFact(
                        "\(review.geometryChangedPageCount)",
                        label: "PAGE SIZE"
                    )
                }
                VStack(spacing: PPSpacing.small) {
                    HStack(spacing: 0) {
                        reviewFact(
                            "\(visibleChangedPageCount)",
                            label: "VISIBLE"
                        )
                        reviewDivider
                        reviewFact(
                            "\(review.textChangedPageCount)",
                            label: "TEXT PAGES"
                        )
                    }
                    HStack(spacing: 0) {
                        reviewFact(
                            "\(textEvidenceCount)",
                            label: "TEXT MARKS"
                        )
                        reviewDivider
                        reviewFact(
                            "\(review.geometryChangedPageCount)",
                            label: "PAGE SIZE"
                        )
                    }
                }
            }
            .padding(.vertical, PPSpacing.medium)
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

            alignmentEvidence

            if !displayedChanges.isEmpty {
                VStack(spacing: 0) {
                    ForEach(
                        Array(displayedChanges.prefix(12).enumerated()),
                        id: \.element.id
                    ) { index, change in
                        changeRow(change)
                        if index < min(displayedChanges.count, 12) - 1 {
                            Rectangle()
                                .fill(PPColor.border.opacity(0.55))
                                .frame(height: 0.6)
                                .padding(.leading, 34)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.68))
                        .frame(height: 0.7)
                }

                if displayedChanges.count > 12 {
                    Text(
                        AppLocalization.format(
                            "%lld more changed page%@",
                            displayedChanges.count - 12,
                            displayedChanges.count - 12 == 1 ? "" : "s"
                        )
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                }
            }

            if onOpenProof != nil || onExportReport != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        reviewActionButtons
                    }
                    VStack(spacing: PPSpacing.small) {
                        reviewActionButtons
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reviewActionButtons: some View {
        if let onOpenProof {
            Button(action: onOpenProof) {
                Label(
                    "Open Full Proof",
                    systemImage: "rectangle.split.2x1"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
            .accessibilityHint(
                "Review both PDFs side by side and correct uncertain page matches."
                    .localizedUI
            )
            .accessibilityIdentifier("openComparisonProof")
        }
        if let onExportReport {
            Button(action: onExportReport) {
                Label(
                    isExportingReport
                        ? "Preparing change report"
                        : "Export Signed Change Report",
                    systemImage: isExportingReport
                        ? "hourglass"
                        : "doc.text"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
            .disabled(isExportingReport)
            .accessibilityHint(
                "Includes bounded text evidence and an Ed25519 signature, but neither PDF file."
                    .localizedUI
            )
            .accessibilityIdentifier("exportChangeReport")
        }
    }

    private var displayedChanges: [PDFPageChange] {
        switch context {
        case .delivery:
            return review.majorVisibleChanges
        case .comparison:
            return review.changes
        }
    }

    private var summaryTitle: String {
        switch context {
        case .delivery:
            guard visibleChangedPageCount > 0 else {
                return "Appearance retained on every page".localizedUI
            }
            return AppLocalization.format(
                "%lld page%@ need visual review",
                visibleChangedPageCount,
                visibleChangedPageCount == 1 ? "" : "s"
            )
        case .comparison:
            guard !review.isIdentical else {
                return "No page changes found".localizedUI
            }
            return AppLocalization.format(
                "%lld changed page%@",
                review.totalChangedPageCount,
                review.totalChangedPageCount == 1 ? "" : "s"
            )
        }
    }

    private var summaryDetail: String {
        switch context {
        case .delivery:
            return AppLocalization.format(
                "Compared all %lld page%@ with the working copy on this device.",
                review.comparedPageCount,
                review.comparedPageCount == 1 ? "" : "s"
            )
        case .comparison:
            return AppLocalization.format(
                "%lld base page%@ · %lld revised page%@ · processed locally",
                review.sourcePageCount,
                review.sourcePageCount == 1 ? "" : "s",
                review.revisedPageCount,
                review.revisedPageCount == 1 ? "" : "s"
            )
        }
    }

    private var summarySymbol: String {
        !summaryHasChanges
            ? "checkmark.circle.fill"
            : "doc.text.magnifyingglass"
    }

    private var summaryColor: Color {
        summaryHasChanges ? PPColor.cyan : PPColor.mint
    }

    private var visibleChangedPageCount: Int {
        switch context {
        case .delivery:
            return review.majorVisibleChanges.count
        case .comparison:
            return review.visibleChangedPageCount
        }
    }

    private var summaryHasChanges: Bool {
        switch context {
        case .delivery:
            return !review.majorVisibleChanges.isEmpty
        case .comparison:
            return !review.isIdentical
        }
    }

    private var textEvidenceCount: Int {
        review.changes.reduce(0) {
            $0 + $1.textDifferenceCount
        }
    }

    @ViewBuilder
    private var alignmentEvidence: some View {
        if review.repeatedTemplateMatchCount > 0
            || review.similarityPageMatchCount > 0
            || review.manualPageMatchCount > 0
            || review.totalVectorDifferenceCount > 0 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.large) {
                    vectorAlignmentFact
                    manualAlignmentFact
                    repeatedTemplateAlignmentFact
                    similarityAlignmentFact
                }
                VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                    vectorAlignmentFact
                    manualAlignmentFact
                    repeatedTemplateAlignmentFact
                    similarityAlignmentFact
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var manualAlignmentFact: some View {
        if review.manualPageMatchCount > 0 {
            Label(
                AppLocalization.format(
                    manualAlignmentFormat,
                    review.manualPageMatchCount,
                    review.manualPageMatchCount == 1 ? "" : "es"
                ),
                systemImage:
                    review.manualPageMatchPersistence
                        == .restoredFromDevice
                        ? "clock.arrow.circlepath"
                        : "checkmark.circle"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.mint)
            .accessibilityHint(
                review.manualPageMatchPersistence == nil
                    ? ""
                    : "Only document identifiers, revision identifiers, and page numbers are retained."
                        .localizedUI
            )
        }
    }

    private var manualAlignmentFormat: String {
        switch review.manualPageMatchPersistence {
        case .savedOnDevice?:
            return "%lld page match%@ saved on this device"
        case .restoredFromDevice?:
            return "%lld saved page match%@ restored on this device"
        case .none:
            return "%lld page match%@ confirmed by you"
        }
    }

    @ViewBuilder
    private var vectorAlignmentFact: some View {
        if review.totalVectorDifferenceCount > 0 {
            Label(
                AppLocalization.format(
                    "%lld vector boundar%@ located",
                    review.totalVectorDifferenceCount,
                    review.totalVectorDifferenceCount == 1
                        ? "y"
                        : "ies"
                ),
                systemImage: "square.dashed"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.cyan)
            .accessibilityHint(
                (
                    onOpenProof == nil
                        ? "Open a changed page to inspect the affected area."
                        : "Open Full Proof to inspect these boundaries."
                ).localizedUI
            )
        }
    }

    @ViewBuilder
    private var repeatedTemplateAlignmentFact: some View {
        if review.repeatedTemplateMatchCount > 0 {
            Label(
                AppLocalization.format(
                    "%lld template page%@ paired by stable order",
                    review.repeatedTemplateMatchCount,
                    review.repeatedTemplateMatchCount == 1 ? "" : "s"
                ),
                systemImage: "square.stack.3d.up"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.cyan)
        }
    }

    @ViewBuilder
    private var similarityAlignmentFact: some View {
        if review.similarityPageMatchCount > 0 {
            Label(
                AppLocalization.format(
                    "%lld page%@ used visual fallback",
                    review.similarityPageMatchCount,
                    review.similarityPageMatchCount == 1 ? "" : "s"
                ),
                systemImage: "viewfinder"
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
        }
    }

    private func reviewFact(
        _ value: String,
        label: String
    ) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold))
                .fontDesign(.serif)
                .monospacedDigit()
                .foregroundStyle(PPColor.textPrimary)
            Text(label.localizedUI)
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var reviewDivider: some View {
        Rectangle()
            .fill(PPColor.border.opacity(0.62))
            .frame(width: 0.6, height: 40)
    }

    private func changeRow(
        _ change: PDFPageChange
    ) -> some View {
        let isFocused = focusedChangeID == change.id
        return Button {
            onOpenChange(change)
        } label: {
            HStack(alignment: .top, spacing: PPSpacing.medium) {
                Image(
                    systemName: isFocused
                        ? "scope"
                        : changeSymbol(change)
                )
                    .font(.body.weight(.semibold))
                    .foregroundStyle(
                        isFocused ? PPColor.mint : PPColor.cyan
                    )
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        changePageLabel(change)
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    Text(changeDetail(change))
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PPSpacing.small)
                HStack(spacing: 4) {
                    Text(change.preferredOpenSide.title.localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(PPColor.cyan)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PPColor.cyan)
                }
                .padding(.top, 3)
            }
            .padding(.vertical, PPSpacing.small)
            .padding(.leading, isFocused ? PPSpacing.small : 0)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isFocused {
                    Rectangle()
                        .fill(PPColor.mint)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                }
            }
        }
        .buttonStyle(.plain)
        .background(
            isFocused ? PPColor.mint.opacity(0.055) : .clear
        )
        .accessibilityIdentifier(
            "changePage-\(change.id)-\(change.preferredOpenSide.rawValue)"
        )
        .accessibilityValue(isFocused ? "Selected".localizedUI : "")
        .accessibilityHint(openPageHint(change))
    }

    private func changePageLabel(
        _ change: PDFPageChange
    ) -> String {
        let source = change.resolvedSourcePageIndex
        let revised = change.resolvedRevisedPageIndex
        if let source, let revised, source != revised {
            return AppLocalization.format(
                "Base %lld → revised %lld",
                source + 1,
                revised + 1
            )
        }
        let pageIndex = change.preferredOpenPageIndex
            ?? change.pageIndex
        return AppLocalization.format(
            "Page %lld",
            pageIndex + 1
        )
    }

    private func openPageHint(
        _ change: PDFPageChange
    ) -> String {
        let pageIndex = change.preferredOpenPageIndex
            ?? change.pageIndex
        switch change.preferredOpenSide {
        case .source:
            return AppLocalization.format(
                "Opens page %lld in the base PDF",
                pageIndex + 1
            )
        case .revised:
            return AppLocalization.format(
                "Opens page %lld in the revised PDF",
                pageIndex + 1
            )
        }
    }

    private func changeSymbol(
        _ change: PDFPageChange
    ) -> String {
        if !change.sourceExists { return "plus.square" }
        if !change.revisedExists { return "minus.square" }
        if change.geometryChanged { return "aspectratio" }
        if change.isVisibleChange { return "eye" }
        return "textformat"
    }

    private func changeDetail(
        _ change: PDFPageChange
    ) -> String {
        if !change.sourceExists {
            return "Added in the revised PDF".localizedUI
        }
        if !change.revisedExists {
            return "Removed from the revised PDF".localizedUI
        }
        var details: [String] = []
        if change.geometryChanged {
            details.append("Page size or rotation changed".localizedUI)
        }
        if change.isVisibleChange {
            details.append(
                AppLocalization.format(
                    "%@ of sampled pixels changed",
                    formattedPixelChange(change.changedPixelRatio)
                )
            )
        }
        if change.textChanged {
            if change.hasLocatedTextDifferences {
                details.append(change.localizedTextEvidenceCountLabel)
                if let preview = change.textDifferencePreview {
                    details.append(
                        String(preview.prefix(96))
                    )
                }
            } else {
                details.append(
                    AppLocalization.format(
                        "%lld to %lld text characters",
                        change.sourceTextCharacterCount,
                        change.revisedTextCharacterCount
                    )
                )
            }
        }
        if change.hasLocatedVectorDifferences {
            details.append(change.localizedVectorEvidenceCountLabel)
        }
        if let matchBasis = change.matchBasis {
            if matchBasis == .repeatedContent
                || matchBasis == .manual {
                details.append(matchBasis.evidenceDetail.localizedUI)
            } else {
                details.append(
                    AppLocalization.format(
                        "Matched by %@",
                        matchBasis.title.localizedUI
                    )
                )
            }
        }
        return details.joined(separator: " · ")
    }

    private func formattedPixelChange(_ ratio: Double) -> String {
        let percentage = min(1, max(0, ratio)) * 100
        if percentage > 0, percentage < 1 {
            return "<1%"
        }
        return AppLocalization.format(
            "%lld%%",
            Int(percentage.rounded())
        )
    }
}

private struct DeliverySealIllustration: View {
    let warning: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(PPColor.surface)
            Circle()
                .stroke(sealColor.opacity(0.85), lineWidth: 1.5)
                .padding(3)
            Circle()
                .stroke(
                    sealColor.opacity(0.5),
                    style: StrokeStyle(lineWidth: 0.8, dash: [2.5, 2.5])
                )
                .padding(9)
            Image(
                systemName: warning
                    ? "checkmark.shield"
                    : "checkmark"
            )
            .font(.title2.bold())
            .foregroundStyle(sealColor)
        }
        .shadow(color: .black.opacity(0.12), radius: 5, y: 3)
        .rotationEffect(.degrees(-7))
        .accessibilityHidden(true)
    }

    private var sealColor: Color {
        warning ? PPColor.amber : PPColor.mint
    }
}
