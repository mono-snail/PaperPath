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
            "\(count) OUTPUT\(count == 1 ? "" : "S")",
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
            "\(count) verified output\(count == 1 ? "" : "s")"
        )
    }
}

struct DeliveryHistoryView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let sourceRecordID: UUID
    let onOpen: (DocumentRoute) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if let source = model.record(id: sourceRecordID) {
                    let outputs = model.verifiedOutputs(
                        for: sourceRecordID
                    )
                    if outputs.isEmpty {
                        ContentUnavailableView(
                            "No verified outputs",
                            systemImage: "clock.badge.questionmark",
                            description: Text(
                                "Verified copies and checked exports appear here."
                            )
                        )
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
                                    SectionEyebrow(text: "SOURCE PRESERVED")
                                    Text(source.displayName)
                                        .font(.title2.bold())
                                        .fontDesign(.serif)
                                        .foregroundStyle(PPColor.textPrimary)
                                        .lineLimit(2)
                                    Text(
                                        "\(outputs.count) verified cop\(outputs.count == 1 ? "y" : "ies")"
                                    )
                                    .font(.subheadline)
                                    .foregroundStyle(PPColor.textSecondary)
                                }
                                .padding(PPSpacing.large)
                                .ppPaper(cornerRadius: 12)

                                VStack(spacing: PPSpacing.medium) {
                                    ForEach(outputs) { output in
                                        outputButton(output)
                                    }
                                }
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
            .navigationTitle("Verified outputs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func outputButton(
        _ output: DocumentRecord
    ) -> some View {
        Button {
            dismiss()
            onOpen(DocumentRoute(recordID: output.id))
        } label: {
            HStack(spacing: PPSpacing.medium) {
                if let url = model.url(for: output.id),
                   !output.profile.isLocked {
                    PDFPageThumbnailView(
                        url: url,
                        pageIndex: 0,
                        refreshToken: model.refreshToken(for: output.id),
                        width: 54
                    )
                } else {
                    ToolSymbolPlate(
                        symbol: output.deliveryReceipt?.operation.symbol
                            ?? "doc",
                        tint: PPColor.mint,
                        size: 48
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        output.deliveryReceipt?.operation.title
                            ?? output.displayName
                    )
                    .font(.headline)
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)

                    Text(output.displayName)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)

                    if let receipt = output.deliveryReceipt {
                        Text(
                            "\(receipt.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(receipt.formattedOutputSize)"
                        )
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: PPSpacing.small)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PPColor.mint)
            }
            .padding(PPSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ppPaper(cornerRadius: 12, shadow: false)
        .accessibilityHint("Opens this verified output")
    }
}

struct DeliveryReceiptView: View {
    private enum ShareArtifactKind: Equatable {
        case pdf
        case deliveryPackage
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recordID: UUID
    let onOpenPage: (UUID, Int) -> Void
    @State private var copyCount = 0
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
    @State private var selectedMilestone: PDFVersionSnapshot?
    @State private var recheckTask: Task<Void, Never>?
    @State private var milestoneProtectionTask:
        Task<Void, Never>?
    @State private var sharePreparationTask:
        Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if let record = model.record(id: recordID),
                   let receipt = record.deliveryReceipt {
                    ScrollView {
                        VStack(
                            alignment: .leading,
                            spacing: PPSpacing.xLarge
                        ) {
                            certificate(record: record, receipt: receipt)
                            deliveryDecisionPanel(record: record, receipt: receipt)
                            if record.hasCurrentDeliveryReceipt {
                                primaryShareAction(receipt)
                            }
                            if let source = model.sourceRecord(for: record) {
                                lineage(source)
                            }
                            if receipt.isVerified {
                                milestoneEvidenceSection(
                                    record: record
                                )
                            }
                            if let review = receipt.changeReview {
                                PDFChangeReviewSummary(
                                    review: review,
                                    context: .delivery,
                                    onOpenChange: { change in
                                        let targetRecordID: UUID?
                                        switch change.preferredOpenSide {
                                        case .revised:
                                            targetRecordID = record.id
                                        case .source:
                                            targetRecordID = model
                                                .sourceRecord(for: record)?.id
                                        }
                                        if let targetRecordID {
                                            onOpenPage(
                                                targetRecordID,
                                                change.pageIndex
                                            )
                                        }
                                    }
                                )
                            }
                            metrics(receipt)
                            checks(receipt)
                            fingerprint(receipt)
                            scope
                        }
                        .frame(maxWidth: 680)
                        .padding(PPSpacing.regular)
                        .frame(maxWidth: .infinity)
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
                if model.url(for: recordID) != nil,
                   model.record(id: recordID)?
                    .hasCurrentDeliveryReceipt == true {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            preparePDFShare()
                        } label: {
                            Label(
                                shareActionTitle,
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .disabled(sharePreparationTask != nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
        .sheet(item: $selectedMilestone) { milestone in
            PDFVersionHistoryView(
                recordID: recordID,
                initialVersionID: milestone.id,
                onOpenPage: onOpenPage
            )
        }
        .task(id: model.record(id: recordID)?.deliveryReceipt?.id) {
            milestoneEvidence = nil
            await loadMilestoneEvidence()
        }
        .onDisappear {
            recheckTask?.cancel()
            recheckTask = nil
            milestoneProtectionTask?.cancel()
            milestoneProtectionTask = nil
            sharePreparationTask?.cancel()
            sharePreparationTask = nil
            preparingShareArtifactKind = nil
            cleanupPreparedShare()
        }
        .sensoryFeedback(.success, trigger: copyCount)
        .sensoryFeedback(
            .success,
            trigger: protectedMilestoneCount
        )
        .sensoryFeedback(
            .success,
            trigger: preparedShareCount
        )
    }

    private func certificate(
        record: DocumentRecord,
        receipt: PDFDeliveryReceipt
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 22))
        let isCurrent = record.hasCurrentDeliveryReceipt
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
                width: dynamicTypeSize.isAccessibilitySize ? 132 : 122,
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
                preparePDFShare()
            } label: {
                Label(
                    preparingShareArtifactKind == .pdf
                        ? "Preparing share"
                        : (
                            receipt.isDeliveryOutput
                                ? "Share verified PDF"
                                : "Share editable PDF"
                        ),
                    systemImage: "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(sharePreparationTask != nil)
            .accessibilityIdentifier(
                receipt.isDeliveryOutput
                    ? "shareVerifiedOutput"
                    : "shareCheckedOutput"
            )

            Button {
                prepareDeliveryPackage()
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
            .disabled(sharePreparationTask != nil)
            .accessibilityHint(
                "Creates a local package that keeps the PDF and its verification evidence together."
                    .localizedUI
            )
            .accessibilityIdentifier("shareDeliveryPackage")

            if preparingShareArtifactKind == .deliveryPackage,
               let progress = model.progress(for: recordID),
               progress.label == "Packaging verified PDF" {
                VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                    LocalOperationProgressView(progress: progress)
                    Button("Stop packaging") {
                        sharePreparationTask?.cancel()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .accessibilityIdentifier("stopDeliveryPackage")
                }
                .padding(.vertical, PPSpacing.xSmall)
            } else {
                Text(
                    "Separate checked copy · \(receipt.outputPageCount) page\(receipt.outputPageCount == 1 ? "" : "s") · \(receipt.formattedOutputSize)"
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
        let isCurrent = record.hasCurrentDeliveryReceipt
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
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }

                Spacer(minLength: PPSpacing.small)

                if !isCurrent {
                    Button {
                        onOpenPage(
                            replacement?.id ?? record.id,
                            0
                        )
                    } label: {
                        Label("Open", systemImage: "arrow.right")
                            .labelStyle(.iconOnly)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                    .accessibilityLabel(
                        replacement == nil
                            ? "Open changed output to verify again"
                            : "Open newer verified copy"
                    )
                }
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

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                deliveryDecisionActionButton(
                    isCurrent
                        ? "Share"
                        : replacement != nil
                            ? "Open latest"
                            : recheckTask == nil
                            ? "Recheck"
                            : "Rechecking",
                    detail: isCurrent
                        ? "Current copy"
                        : replacement == nil
                            ? "Verify changed output"
                            : "Verified copy",
                    symbol: isCurrent
                        ? "square.and.arrow.up"
                        : "arrow.triangle.2.circlepath",
                    tint: tint
                ) {
                    if isCurrent, receipt.isVerified {
                        preparePDFShare()
                    } else if let replacement {
                        onOpenPage(replacement.id, 0)
                    } else {
                        recheck(record)
                    }
                }
                .disabled(!isCurrent && recheckTask != nil)

                deliveryDecisionActionButton(
                    firstChange == nil ? "No visible drift" : "Open drift",
                    detail: firstChange.map {
                        "Page \($0.pageIndex + 1)"
                    } ?? "Pixel clear",
                    symbol: firstChange == nil
                        ? "eye.slash"
                        : "eye",
                    tint: firstChange == nil ? PPColor.mint : PPColor.cyan
                ) {
                    if let firstChange {
                        let targetRecordID: UUID
                        switch firstChange.preferredOpenSide {
                        case .revised:
                            targetRecordID = record.id
                        case .source:
                            targetRecordID = model.sourceRecord(for: record)?
                                .id ?? record.id
                        }
                        onOpenPage(targetRecordID, firstChange.pageIndex)
                    }
                }

                deliveryDecisionActionButton(
                    "Copy hash",
                    detail: receipt.shortFingerprint.uppercased(),
                    symbol: "number",
                    tint: PPColor.accent
                ) {
                    SecurePasteboard.copy(receipt.sha256)
                    copyCount += 1
                }
            }

            VStack(alignment: .leading, spacing: PPSpacing.small) {
                deliveryDecisionActionButton(
                    isCurrent
                        ? "Share"
                        : replacement != nil
                            ? "Open latest"
                            : recheckTask == nil
                            ? "Recheck"
                            : "Rechecking",
                    detail: isCurrent
                        ? "Current copy"
                        : replacement == nil
                            ? "Verify changed output"
                            : "Verified copy",
                    symbol: isCurrent
                        ? "square.and.arrow.up"
                        : "arrow.triangle.2.circlepath",
                    tint: tint
                ) {
                    if isCurrent, receipt.isVerified {
                        preparePDFShare()
                    } else if let replacement {
                        onOpenPage(replacement.id, 0)
                    } else {
                        recheck(record)
                    }
                }
                .disabled(!isCurrent && recheckTask != nil)

                deliveryDecisionActionButton(
                    firstChange == nil ? "No visible drift" : "Open drift",
                    detail: firstChange.map {
                        "Page \($0.pageIndex + 1)"
                    } ?? "Pixel clear",
                    symbol: firstChange == nil
                        ? "eye.slash"
                        : "eye",
                    tint: firstChange == nil ? PPColor.mint : PPColor.cyan
                ) {
                    if let firstChange {
                        let targetRecordID: UUID
                        switch firstChange.preferredOpenSide {
                        case .revised:
                            targetRecordID = record.id
                        case .source:
                            targetRecordID = model.sourceRecord(for: record)?
                                .id ?? record.id
                        }
                        onOpenPage(targetRecordID, firstChange.pageIndex)
                    }
                }

                deliveryDecisionActionButton(
                    "Copy hash",
                    detail: receipt.shortFingerprint.uppercased(),
                    symbol: "number",
                    tint: PPColor.accent
                ) {
                    SecurePasteboard.copy(receipt.sha256)
                    copyCount += 1
                }
            }
        }
        .padding(.top, PPSpacing.xSmall)
    }

    private func recheck(_ record: DocumentRecord) {
        guard recheckTask == nil else { return }
        recheckTask = Task { @MainActor in
            defer { recheckTask = nil }
            guard let created = await model.createSafeShareCopy(
                recordID: record.id
            ),
            !Task.isCancelled
            else { return }
            onOpenPage(created.id, 0)
        }
    }

    private func preparePDFShare() {
        guard sharePreparationTask == nil else { return }
        cleanupPreparedShare()
        preparingShareArtifactKind = .pdf
        sharePreparationTask = Task { @MainActor in
            defer {
                sharePreparationTask = nil
                preparingShareArtifactKind = nil
            }
            guard let url = await model.makeFilesExportCopy(
                recordID: recordID
            ) else { return }
            guard !Task.isCancelled,
                  model.record(id: recordID)?
                    .hasCurrentDeliveryReceipt == true
            else {
                await model.discardFilesExportCopy(at: url)
                if !Task.isCancelled {
                    model.noticeMessage =
                        "The PDF changed before sharing. Verify it again."
                            .localizedUI
                }
                return
            }
            shareURL = url
            shareArtifactKind = .pdf
            preparedShareCount += 1
            isSharing = true
        }
    }

    private func prepareDeliveryPackage() {
        guard sharePreparationTask == nil else { return }
        cleanupPreparedShare()
        preparingShareArtifactKind = .deliveryPackage
        sharePreparationTask = Task { @MainActor in
            defer {
                sharePreparationTask = nil
                preparingShareArtifactKind = nil
            }
            guard let url = await model.makeDeliveryPackage(
                recordID: recordID
            ) else { return }
            guard !Task.isCancelled else {
                await model.discardDeliveryPackage(at: url)
                return
            }
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
            }
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
                        .lineLimit(1)
                    Text(detail.localizedUI)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 38)
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
                    .lineLimit(1)
                Text(label.localizedUI)
                    .font(.caption2.smallCaps().weight(.medium))
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 92, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var shareActionTitle: String {
        model.record(id: recordID)?.deliveryReceipt?
            .isDeliveryOutput == false
            ? "Share editable PDF"
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
        HStack(spacing: PPSpacing.medium) {
            Image(systemName: "arrow.triangle.branch")
                .font(.body.weight(.semibold))
                .foregroundStyle(PPColor.cyan)
                .frame(width: 32, height: 32)
                .background(PPColor.cyan.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("CREATED FROM")
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                Text(source.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            Text("SOURCE KEPT")
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(PPColor.mint)
        }
        .padding(PPSpacing.medium)
        .ppPaper(cornerRadius: 10, shadow: false)
        .accessibilityElement(children: .combine)
    }

    private var linkedMilestones: [PDFVersionSnapshot] {
        milestoneEvidence?.linkedMilestones ?? []
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
                        Array(linkedMilestones.prefix(4).enumerated()),
                        id: \.element.id
                    ) { index, milestone in
                        Button {
                            selectedMilestone = milestone
                        } label: {
                            HStack(spacing: PPSpacing.medium) {
                                Image(systemName: "pin.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PPColor.mint)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(milestone.displayTitle.localizedUI)
                                        .font(
                                            .subheadline.weight(.semibold)
                                        )
                                        .fontDesign(.serif)
                                        .foregroundStyle(PPColor.textPrimary)
                                        .lineLimit(1)
                                    Text(
                                        "\(milestone.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(milestone.formattedSize)"
                                    )
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(
                                        PPColor.textSecondary
                                    )
                                }
                                Spacer(minLength: 0)
                                Text("OPEN VERSION".localizedUI)
                                    .font(
                                        .caption2.smallCaps().weight(.bold)
                                    )
                                    .foregroundStyle(PPColor.cyan)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(PPColor.cyan)
                            }
                            .padding(.vertical, PPSpacing.small)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "openLinkedMilestone-\(milestone.id.uuidString)"
                        )

                        if index < min(linkedMilestones.count, 4) - 1 {
                            Rectangle()
                                .fill(PPColor.border.opacity(0.54))
                                .frame(height: 0.6)
                                .padding(.leading, 36)
                        }
                    }

                    if linkedMilestones.count > 4,
                       let first = linkedMilestones.first {
                        Button {
                            selectedMilestone = first
                        } label: {
                            Label(
                                AppLocalization.format(
                                    "View all %lld linked milestones",
                                    linkedMilestones.count
                                ),
                                systemImage: "clock.arrow.circlepath"
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
                    }
                }
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
                                record.profile.formattedSize
                            )
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
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
            .disabled(milestoneProtectionTask != nil)
            .accessibilityLabel(
                (
                    availability == .protectCurrent
                        ? "Protect verified version"
                        : "Protect matching recovery version"
                ).localizedUI
            )
            .accessibilityHint(
                "Keeps an exact local version linked to this receipt."
                    .localizedUI
            )
            .accessibilityIdentifier("protectDeliveryMilestone")
        } else {
            HStack(alignment: .top, spacing: PPSpacing.medium) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Matching version unavailable".localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(
                        "The receipt remains, but its exact PDF version is no longer in local history."
                            .localizedUI
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

    private var milestoneEvidenceDetail: String {
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
            return "No exact local version matches this receipt".localizedUI
        }
    }

    private func loadMilestoneEvidence() async {
        guard let receiptID = model.record(id: recordID)?
            .deliveryReceipt?.id
        else {
            milestoneEvidence = .unavailable
            return
        }
        let loaded = await model.deliveryMilestoneEvidence(
            recordID: recordID,
            receiptID: receiptID
        )
        guard !Task.isCancelled else { return }
        milestoneEvidence = loaded
    }

    private func protectDeliveryMilestone() {
        guard milestoneProtectionTask == nil else { return }
        milestoneProtectionTask = Task { @MainActor in
            defer { milestoneProtectionTask = nil }
            let protected = await model.protectDeliveryReceiptMilestone(
                recordID: recordID
            )
            guard !Task.isCancelled else { return }
            if protected != nil {
                await loadMilestoneEvidence()
                guard !Task.isCancelled else { return }
                protectedMilestoneCount += 1
            }
        }
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
            HStack {
                SectionEyebrow(text: "SHA-256 FILE FINGERPRINT")
                Spacer()
                Button("Copy") {
                    SecurePasteboard.copy(receipt.sha256)
                    copyCount += 1
                }
                .font(.caption.weight(.semibold))
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
                    "SHA-256 fingerprint \(receipt.sha256)"
                )
        }
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
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let sourceRecordID: UUID
    let onOpenPage: (UUID, Int) -> Void

    @State private var revisedRecordID: UUID?
    @State private var review: PDFChangeReview?
    @State private var errorMessage: String?
    @State private var isComparing = false
    @State private var comparisonTask: Task<Void, Never>?
    @State private var comparisonGeneration = 0

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
                            compareAction

                            if isComparing {
                                processing
                            } else if let review {
                                PDFChangeReviewSummary(
                                    review: review,
                                    context: .comparison,
                                    onOpenChange: { change in
                                        guard let revisedRecordID else {
                                            return
                                        }
                                        let targetRecordID =
                                            change.preferredOpenSide
                                                == .revised
                                            ? revisedRecordID
                                            : sourceRecordID
                                        onOpenPage(
                                            targetRecordID,
                                            change.pageIndex
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
                    Button((isComparing ? "Stop" : "Done").localizedUI) {
                        if isComparing {
                            stopComparison()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .task {
            if revisedRecordID == nil {
                revisedRecordID = candidates.first?.id
            }
        }
        .onChange(of: revisedRecordID) {
            stopComparison()
            review = nil
            errorMessage = nil
        }
        .onDisappear {
            comparisonTask?.cancel()
            comparisonTask = nil
        }
        .sensoryFeedback(
            .success,
            trigger: review?.totalChangedPageCount
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
                    .lineLimit(1)
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
        HStack(spacing: PPSpacing.medium) {
            ProgressView()
                .tint(PPColor.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text("Comparing every page")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text("Visible content, text layer, and geometry")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
            Spacer()
            Button("Stop") {
                stopComparison()
            }
            .font(.caption.weight(.semibold))
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

    private func startComparison() {
        guard let revisedRecordID else { return }
        stopComparison()
        comparisonGeneration += 1
        let generation = comparisonGeneration
        review = nil
        errorMessage = nil
        isComparing = true
        comparisonTask = Task {
            do {
                let result = try await model.comparePDFs(
                    sourceRecordID: sourceRecordID,
                    revisedRecordID: revisedRecordID
                )
                try Task.checkCancellation()
                guard generation == comparisonGeneration else {
                    return
                }
                review = result
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isComparing = false
            comparisonTask = nil
        }
    }

    private func stopComparison() {
        comparisonGeneration += 1
        comparisonTask?.cancel()
        comparisonTask = nil
        isComparing = false
    }
}

private struct PDFChangeReviewSummary: View {
    enum Context {
        case delivery
        case comparison
    }

    let review: PDFChangeReview
    let context: Context
    let onOpenChange: (PDFPageChange) -> Void

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
                    label: "WORD MARKS"
                )
                reviewDivider
                reviewFact(
                    "\(review.geometryChangedPageCount)",
                    label: "PAGE SIZE"
                )
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
        Button {
            onOpenChange(change)
        } label: {
            HStack(alignment: .top, spacing: PPSpacing.medium) {
                Image(systemName: changeSymbol(change))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PPColor.cyan)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        AppLocalization.format(
                            "Page %lld",
                            change.pageIndex + 1
                        )
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            "changePage-\(change.pageIndex + 1)-\(change.preferredOpenSide.rawValue)"
        )
        .accessibilityHint(openPageHint(change))
    }

    private func openPageHint(
        _ change: PDFPageChange
    ) -> String {
        switch change.preferredOpenSide {
        case .source:
            return AppLocalization.format(
                "Opens page %lld in the base PDF",
                change.pageIndex + 1
            )
        case .revised:
            return AppLocalization.format(
                "Opens page %lld in the revised PDF",
                change.pageIndex + 1
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
                    "%lld%% of sampled pixels changed",
                    Int((change.changedPixelRatio * 100).rounded())
                )
            )
        }
        if change.textChanged {
            if change.hasLocatedTextDifferences {
                details.append(
                    AppLocalization.format(
                        change.hasCharacterDifferences
                            ? "%lld character-level text mark%@"
                            : "%lld word-level text mark%@",
                        change.textDifferenceCount,
                        change.textDifferenceCount == 1 ? "" : "s"
                    )
                )
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
        if let matchBasis = change.matchBasis {
            details.append(
                AppLocalization.format(
                    "Matched by %@",
                    matchBasis.title.localizedUI
                )
            )
        }
        return details.joined(separator: " · ")
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
