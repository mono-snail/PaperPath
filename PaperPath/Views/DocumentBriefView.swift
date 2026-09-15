import SwiftUI

struct DocumentBriefView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let onOpenPage: (Int) -> Void
    let onStep: (SuggestedStep, Int?) -> Void

    @State private var tagText = ""
    @StateObject private var factCopy =
        SecurePasteboardCopyController()
    @State private var copiedFactIdentity: String?
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisGeneration = UUID()
    @State private var analysisErrorMessage: String?
    @State private var analysisErrorFeedback = 0
    @State private var metadataTask: Task<Void, Never>?
    @State private var metadataGeneration = UUID()
    @State private var metadataStopRequested = false
    @State private var showsMoreDetails = false
    @State private var isConfirmingTagDiscard = false
    @State private var didLoadTagDraft = false
    @State private var reloadsTagDraftWhenActive = false
    @State private var originalTags: [String] = []

    init(
        recordID: UUID,
        onOpenPage: @escaping (Int) -> Void = { _ in },
        onStep: @escaping (SuggestedStep, Int?) -> Void
    ) {
        self.recordID = recordID
        self.onOpenPage = onOpenPage
        self.onStep = onStep
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                if model.record(id: recordID) == nil {
                    ContentUnavailableView(
                        "Working copy unavailable",
                        systemImage: "doc.badge.ellipsis",
                        description: Text(
                            "This private working copy is no longer available."
                        )
                    )
                    .padding(PPSpacing.regular)
                } else if model.isAnalyzing(recordID)
                            || analysisTask != nil {
                    PPEmptyState(
                        kind: .processing,
                        title: "Analyzing document",
                        message: "Building the private on-device brief."
                    )
                    .padding(PPSpacing.regular)
                } else if let record = model.record(id: recordID),
                   let brief = record.brief {
                    content(record: record, brief: brief)
                } else {
                    VStack(spacing: PPSpacing.medium) {
                        ContentUnavailableView(
                            "Brief unavailable",
                            systemImage: "list.bullet.rectangle.portrait",
                            description: Text(
                                "PaperPath has not indexed this document yet."
                            )
                        )
                        Button {
                            retryAnalysis()
                        } label: {
                            Label(
                                analysisTask == nil
                                    ? "Analyze Again".localizedUI
                                    : "Analyzing document".localizedUI,
                                systemImage: "arrow.clockwise"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PPPrimaryButtonStyle())
                        .disabled(analysisTask != nil)
                        .accessibilityIdentifier(
                            "retryDocumentBrief"
                        )
                        if let analysisErrorMessage {
                            Label(
                                analysisErrorMessage.localizedUI,
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.amber)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                        }
                    }
                    .frame(maxWidth: 520)
                    .padding(PPSpacing.regular)
                }
            }
            .navigationTitle("Document details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            metadataStopRequested
                                ? "Stopping"
                                : hasActiveTask
                                    ? "Stop"
                                    : "Close"
                        ).localizedUI
                    ) {
                        if hasActiveTask {
                            interruptActiveWork()
                        } else {
                            requestDismissal()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(metadataStopRequested)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                if let record = model.record(id: recordID) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            performMetadataUpdate {
                                await model.togglePinned(
                                    recordID: recordID,
                                    expectedIsPinned:
                                        record.isPinned
                                )
                            }
                        } label: {
                            if metadataTask != nil {
                                ProgressView()
                            } else {
                                Image(
                                    systemName:
                                        record.isPinned ? "pin.fill" : "pin"
                                )
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .disabled(hasActiveTask)
                        .accessibilityLabel(
                            (
                                record.isPinned
                                    ? "Unpin"
                                    : "Pin"
                            ).localizedUI
                        )
                        .accessibilityValue(
                            metadataTask == nil
                                ? ""
                                : "Updating".localizedUI
                        )
                    }
                }
            }
        }
        .confirmationDialog(
            "Discard tag changes?".localizedUI,
            isPresented: $isConfirmingTagDiscard,
            titleVisibility: .visible
        ) {
            Button(
                "Discard Tag Changes".localizedUI,
                role: .destructive
            ) {
                tagText = ""
                dismiss()
            }
            Button("Keep Editing".localizedUI, role: .cancel) {}
        } message: {
            Text(
                "Tag changes have not been saved.".localizedUI
            )
        }
        .interactiveDismissDisabled(hasActiveTask || hasTagChanges)
        .accessibilityAction(.escape) {
            if hasActiveTask {
                interruptActiveWork()
            } else {
                requestDismissal()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                factCopy.synchronizeOwnership()
                if reloadsTagDraftWhenActive,
                   UIApplication.shared.isProtectedDataAvailable {
                    reloadsTagDraftWhenActive = false
                    reloadTagDraft()
                }
            } else if phase == .background {
                reloadsTagDraftWhenActive = true
                didLoadTagDraft = false
                interruptProtectedBriefWork()
                resetFactCopyState()
                tagText = ""
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIPasteboard.changedNotification
            )
        ) { _ in
            factCopy.synchronizeOwnership()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            reloadsTagDraftWhenActive = true
            didLoadTagDraft = false
            interruptProtectedBriefWork()
            resetFactCopyState()
            tagText = ""
        }
        .onDisappear {
            interruptProtectedBriefWork()
            resetFactCopyState()
            tagText = ""
            didLoadTagDraft = false
        }
        .onChange(of: tagText) { _, value in
            if value.count > 200 {
                tagText = String(value.prefix(200))
            }
        }
        .onChange(of: factCopy.status) { _, status in
            if status != .copied {
                copiedFactIdentity = nil
            }
        }
        .onChange(of: currentFactIdentities) { _, identities in
            guard let copiedFactIdentity,
                  !identities.contains(copiedFactIdentity)
            else { return }
            resetFactCopyState()
        }
        .sensoryFeedback(
            .success,
            trigger: factCopy.successFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: factCopy.errorFeedback
        )
        .sensoryFeedback(.error, trigger: analysisErrorFeedback)
    }

    private func content(
        record: DocumentRecord,
        brief: DocumentBrief
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPSpacing.large) {
                overview(record: record, brief: brief)
                if !brief.suggestedSteps.isEmpty {
                    suggestedSteps(brief.suggestedSteps, record: record)
                }
                if !brief.entities.isEmpty {
                    facts(
                        brief.entities,
                        contentRevisionID:
                            record.contentRevisionID
                    )
                }
                moreDetails(record: record, brief: brief)
            }
            .frame(maxWidth: 920)
            .padding(PPSpacing.regular)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            loadTagDraftIfNeeded(from: record)
        }
    }

    private func overview(
        record: DocumentRecord,
        brief: DocumentBrief
    ) -> some View {
        HStack(alignment: .center, spacing: PPSpacing.medium) {
            if horizontalSizeClass == .regular,
               !dynamicTypeSize.ppPrefersExpandedLayout {
                documentCover(record)
                    .scaleEffect(0.72)
                    .frame(width: 100, height: 126)
            }
            WorkflowCommandHeader(
                eyebrow: "SUMMARY",
                title: record.displayName,
                detail: overviewDetail(
                    record: record,
                    brief: brief
                ),
                symbol: brief.category.symbol,
                tint: confidenceColor(brief.resolvedConfidence),
                metrics: []
            )
        }
    }

    private func overviewDetail(
        record: DocumentRecord,
        brief: DocumentBrief
    ) -> String {
        switch record.profile.kind {
        case .form:
            return AppLocalization.format(
                "%lld fillable field%@ found. Complete required fields before sharing.",
                record.profile.formFieldCount,
                record.profile.formFieldCount == 1 ? "" : "s"
            )
        case .scan:
            return "This PDF is image-based. Recognize text to search or copy it."
        case .mixed:
            return "Some pages may need text recognition before you can search or copy them."
        case .protected:
            return "Unlock this PDF to inspect or edit its contents."
        case .text:
            return brief.summary
        }
    }

    private func moreDetails(
        record: DocumentRecord,
        brief: DocumentBrief
    ) -> some View {
        DisclosureGroup(
            isExpanded: $showsMoreDetails
        ) {
            VStack(
                alignment: .leading,
                spacing: PPSpacing.large
            ) {
                workflow(record)
                organization(record)
                fileDetails(record)
                indexEvidence(brief)
            }
            .padding(.top, PPSpacing.medium)
        } label: {
            Label(
                "More document details",
                systemImage: "info.circle"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PPColor.textPrimary)
            .frame(minHeight: 44)
        }
        .tint(PPColor.cyan)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private func documentCover(_ record: DocumentRecord) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PPColor.elevated)
                .frame(width: 120, height: 154)
                .offset(x: 6, y: 5)

            if let url = model.url(for: recordID) {
                PDFPageThumbnailView(
                    url: url,
                    pageIndex: 0,
                    refreshToken: model.refreshToken(for: recordID),
                    width: 120
                )
                .shadow(color: .black.opacity(0.14), radius: 9, y: 5)
            } else {
                PaperScanIllustration()
                    .scaleEffect(0.7)
                    .frame(width: 120, height: 154)
            }

            Text("\(record.profile.pageCount)P")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .padding(.horizontal, 6)
                .frame(height: 21)
                .background(PPColor.accent)
                .clipShape(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .offset(x: 4, y: 5)

            Image(systemName: "paperclip")
                .font(.title3.weight(.medium))
                .foregroundStyle(PPColor.textSecondary)
                .rotationEffect(.degrees(-16))
                .offset(x: -88, y: -8)

            Text("ANALYZED")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(PPColor.mint.opacity(0.78))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(
                            PPColor.mint.opacity(0.56),
                            lineWidth: 0.8
                        )
                }
                .rotationEffect(.degrees(-7))
                .offset(x: -4, y: 126)
        }
        .frame(width: 132, height: 166)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("First page preview")
    }

    private func workflow(_ record: DocumentRecord) -> some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(VStackLayout(spacing: PPSpacing.medium))
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

        return VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "WORKFLOW")
            layout {
                Menu {
                    ForEach(DocumentWorkflowStatus.allCases) { status in
                        Button {
                            performMetadataUpdate {
                                await model.updateWorkflow(
                                    recordID: recordID,
                                    status: status
                                )
                            }
                        } label: {
                            Label(
                                status.title.localizedUI,
                                systemImage: status.symbol
                            )
                        }
                    }
                } label: {
                    Label(
                        record.workflowStatus.title,
                        systemImage: record.workflowStatus.symbol
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
                .disabled(hasActiveTask)

                if record.workflowStatus != .ready {
                    Button {
                        performMetadataUpdate {
                            await model.updateWorkflow(
                                recordID: recordID,
                                status: .ready
                            )
                        }
                    } label: {
                        Label("Mark Ready", systemImage: "checkmark")
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .disabled(hasActiveTask)
                }
            }
        }
    }

    private func suggestedSteps(
        _ steps: [SuggestedStep],
        record: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "SUGGESTED NEXT STEPS")
            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    let isCompleted = record.completedActions.contains(
                        DocumentActionPlanner.action(for: step)
                    )
                    Button {
                        performAfterSavingTags(
                            expectedContentRevisionID:
                                record.contentRevisionID
                        ) {
                            onStep(
                                step,
                                evidencePage(for: step)
                            )
                        }
                    } label: {
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
                            HStack(
                                alignment: .top,
                                spacing: PPSpacing.medium
                            ) {
                                VStack(spacing: 3) {
                                    Image(
                                        systemName: isCompleted
                                            ? "checkmark.circle.fill"
                                            : step.kind.symbol
                                    )
                                    .font(.caption.weight(.semibold))
                                    if !isCompleted {
                                        Text(
                                            String(
                                                format: "%02d",
                                                index + 1
                                            )
                                        )
                                        .font(.caption2.weight(.bold))
                                        .monospacedDigit()
                                    }
                                }
                                .foregroundStyle(
                                    isCompleted
                                        ? PPColor.mint
                                        : PPColor.accent
                                )
                                .frame(width: 34)
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(PPColor.border.opacity(0.64))
                                        .frame(width: 0.6, height: 40)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(step.title.localizedUI)
                                        .font(
                                            .subheadline.weight(.semibold)
                                        )
                                        .foregroundStyle(
                                            PPColor.textPrimary
                                        )
                                    Text(step.evidence.localizedUI)
                                        .font(.caption)
                                        .foregroundStyle(
                                            PPColor.textSecondary
                                        )
                                        .lineLimit(
                                            dynamicTypeSize
                                                .ppPrefersExpandedLayout
                                                ? nil
                                                : 3
                                        )
                                        .fixedSize(
                                            horizontal: false,
                                            vertical: true
                                        )
                                    if isCompleted {
                                        Text("COMPLETED")
                                            .font(
                                                .caption2.smallCaps()
                                                    .weight(.bold)
                                            )
                                            .foregroundStyle(PPColor.mint)
                                    }
                                }
                                if !dynamicTypeSize.ppPrefersExpandedLayout {
                                    Spacer(minLength: 0)
                                }
                            }

                            HStack(spacing: PPSpacing.small) {
                                if let pageIndex =
                                    step.evidencePageIndex {
                                    Text("p\(pageIndex + 1)")
                                        .font(.caption2.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(
                                            PPColor.textSecondary
                                        )
                                }
                                Image(
                                    systemName: isCompleted
                                        ? "checkmark"
                                        : "arrow.up.right"
                                )
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PPColor.textSecondary)
                            }
                            .frame(
                                maxWidth:
                                    dynamicTypeSize
                                        .ppPrefersExpandedLayout
                                        ? .infinity
                                        : nil,
                                alignment: .trailing
                            )
                        }
                        .padding(.vertical, PPSpacing.medium)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(hasActiveTask)

                    if index < steps.count - 1 {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.65))
                            .frame(height: 0.6)
                            .padding(.leading, 46)
                    }
                }
            }
            .padding(.horizontal, PPSpacing.regular)
            .padding(.vertical, PPSpacing.small)
            .ppPaper(cornerRadius: 10, shadow: false)
        }
    }

    private func facts(
        _ entities: [DetectedEntity],
        contentRevisionID: UUID
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "DETECTED FACTS")
            factCopyStatusLabel(entities)
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 210),
                        spacing: PPSpacing.medium
                    )
                ],
                spacing: PPSpacing.medium
            ) {
                ForEach(entities) { entity in
                    factItem(
                        entity,
                        contentRevisionID:
                            contentRevisionID
                    )
                }
            }
        }
    }

    private func factItem(
        _ entity: DetectedEntity,
        contentRevisionID: UUID
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
                    alignment: .center,
                    spacing: PPSpacing.xSmall
                )
            )
        return layout {
            Button {
                copyFact(
                    entity,
                    expectedContentRevisionID:
                        contentRevisionID
                )
            } label: {
                factRow(entity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AppLocalization.format(
                    "Copy %@: %@",
                    entity.kind.title.localizedUI,
                    entity.value
                )
            )
            .accessibilityValue(
                factAccessibilityValue(entity)
            )
            .accessibilityHint(
                (
                    isCopiedFact(entity)
                        ? "Copies this fact again and restarts the five-minute expiry."
                        : "Copies this fact locally for five minutes."
                ).localizedUI
            )

            if let pageIndex = entity.pageIndex {
                Button {
                    performAfterSavingTags(
                        expectedContentRevisionID:
                            contentRevisionID
                    ) {
                        onOpenPage(pageIndex)
                    }
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.cyan)
                .frame(
                    maxWidth:
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? .infinity
                            : nil,
                    alignment: .trailing
                )
                .disabled(hasActiveTask)
                .accessibilityLabel(
                    AppLocalization.format(
                        "Open %@ evidence on page %lld",
                        entity.kind.title.localizedUI,
                        pageIndex + 1
                    )
                )
                .accessibilityHint(
                    "Returns to the supporting page in the PDF."
                        .localizedUI
                )
            }
        }
        .padding(.vertical, PPSpacing.medium)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    @ViewBuilder
    private func factCopyStatusLabel(
        _ entities: [DetectedEntity]
    ) -> some View {
        switch factCopy.status {
        case .idle:
            EmptyView()
        case .copied:
            if let entity = entities.first(
                where: isCopiedFact
            ) {
                Label(
                    AppLocalization.format(
                        "%@ copied locally for five minutes",
                        entity.kind.title.localizedUI
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(PPColor.mint)
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            }
        case .failed:
            Label(
                "Fact could not be copied".localizedUI,
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(PPColor.amber)
            .font(.caption.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func factRow(
        _ entity: DetectedEntity
    ) -> some View {
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
                    spacing: PPSpacing.medium
                )
            )
        return layout {
            HStack(spacing: PPSpacing.medium) {
                Image(systemName: entity.kind.symbol)
                    .foregroundStyle(entityColor(entity.kind))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entity.kind.title.localizedUI)
                        .font(.caption.smallCaps().weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                    Text(entity.value)
                        .font(.subheadline.weight(.medium))
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
                }
            }
            .layoutPriority(1)

            if !dynamicTypeSize.ppPrefersExpandedLayout {
                Spacer(minLength: 0)
            }

            HStack(spacing: PPSpacing.xSmall) {
                if let pageIndex = entity.pageIndex {
                    Text("p\(pageIndex + 1)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textSecondary)
                }
                Image(
                    systemName: isCopiedFact(entity)
                        ? "checkmark.circle.fill"
                        : "doc.on.doc"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isCopiedFact(entity)
                        ? PPColor.mint
                        : PPColor.textSecondary
                )
                .accessibilityHidden(true)
            }
            .frame(
                maxWidth:
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? .infinity
                        : nil,
                alignment: .trailing
            )
        }
    }

    private var currentFactIdentities: [String] {
        model.record(id: recordID)?
            .brief?
            .entities
            .map(factIdentity) ?? []
    }

    private func factIdentity(
        _ entity: DetectedEntity
    ) -> String {
        "\(entity.id.uuidString)|\(entity.value)"
    }

    private func isCopiedFact(
        _ entity: DetectedEntity
    ) -> Bool {
        factCopy.status == .copied
            && copiedFactIdentity == factIdentity(entity)
    }

    private func factAccessibilityValue(
        _ entity: DetectedEntity
    ) -> String {
        var values: [String] = []
        if let pageIndex = entity.pageIndex {
            values.append(
                AppLocalization.format(
                    "Page %lld",
                    pageIndex + 1
                )
            )
        }
        if isCopiedFact(entity) {
            values.append(
                "Copied locally for five minutes".localizedUI
            )
        }
        return values.joined(separator: ", ")
    }

    private func copyFact(
        _ entity: DetectedEntity,
        expectedContentRevisionID: UUID
    ) {
        guard model.record(id: recordID)?.contentRevisionID
                == expectedContentRevisionID
        else {
            resetFactCopyState()
            model[noticeFor: paperPathSceneID] =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            return
        }
        if factCopy.copy(entity.value) {
            copiedFactIdentity = factIdentity(entity)
        } else {
            copiedFactIdentity = nil
        }
    }

    private func resetFactCopyState() {
        factCopy.reset()
        copiedFactIdentity = nil
    }

    private func organization(_ record: DocumentRecord) -> some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(VStackLayout(spacing: PPSpacing.medium))
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

        return VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "ORGANIZE")
            layout {
                HStack(spacing: PPSpacing.xSmall) {
                    TextField("contract, client", text: $tagText)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit {
                            saveTags()
                        }
                        .font(.body)
                        .disabled(hasActiveTask)
                    PasteButton(
                        payloadType: String.self
                    ) { values in
                        pasteTags(values.first)
                    }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(hasActiveTask)
                    .accessibilityLabel("Paste tags")
                }
                .padding(.leading, PPSpacing.medium)
                .padding(.trailing, PPSpacing.xSmall)
                .background(PPColor.surfaceMuted)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                )
                Button {
                    saveTags()
                } label: {
                    if dynamicTypeSize.ppPrefersExpandedLayout {
                        Label("Save Tags", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    } else {
                        Image(systemName: "checkmark")
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.mint))
                .disabled(hasActiveTask || !hasTagChanges)
                .accessibilityLabel("Save tags")
                .accessibilityHint(tagSaveAccessibilityHint)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    tagGuidance
                    Spacer(minLength: 0)
                    tagCount
                }
                VStack(alignment: .leading, spacing: 3) {
                    tagGuidance
                    tagCount
                }
            }
        }
    }

    private var tagGuidance: some View {
        Text(
            "Separate tags with commas. Tags are included in local search."
        )
        .font(.caption)
        .foregroundStyle(PPColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tagCount: some View {
        Text(
            AppLocalization.format(
                "%lld of 8 tags",
                normalizedTagDraft.count
            )
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(
            normalizedTagDraft.count == 8
                ? PPColor.amber
                : PPColor.textSecondary
        )
    }

    private func indexEvidence(_ brief: DocumentBrief) -> some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

        return layout {
            ZStack {
                Circle()
                    .stroke(PPColor.mint.opacity(0.68), lineWidth: 1)
                Circle()
                    .stroke(
                        PPColor.mint.opacity(0.28),
                        style: StrokeStyle(
                            lineWidth: 0.7,
                            dash: [2, 2]
                        )
                    )
                    .padding(4)
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(PPColor.mint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text("Private local index")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(
                    AppLocalization.format(
                        "Source: %@ · PDF content stays local",
                        (
                            brief.textSource?.title
                                ?? "Document metadata"
                        ).localizedUI
                    )
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !dynamicTypeSize.ppPrefersExpandedLayout {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, PPSpacing.medium)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private func fileDetails(_ record: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "FILE")
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 140), spacing: PPSpacing.medium)
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
                    label: "Working copy",
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

    private func entityColor(_ kind: DetectedEntity.Kind) -> Color {
        switch kind {
        case .date: return PPColor.amber
        case .amount: return PPColor.mint
        case .email, .phone, .link: return PPColor.cyan
        case .reference: return PPColor.accent
        case .identifier: return Color.red
        }
    }

    private func evidencePage(for step: SuggestedStep) -> Int? {
        if let evidencePageIndex = step.evidencePageIndex {
            return evidencePageIndex
        }
        switch step.kind {
        case .reviewDate, .reviewAmount, .reviewSignature:
            return model.matchingPage(
                recordID: recordID,
                query: step.evidence
            )
        case .completeForm:
            return 0
        case .recognize, .organize, .share:
            return nil
        }
    }

    private func confidenceColor(
        _ confidence: DocumentUnderstandingConfidence
    ) -> Color {
        switch confidence {
        case .high: return PPColor.mint
        case .medium: return PPColor.cyan
        case .low: return PPColor.amber
        }
    }

    private func performMetadataUpdate(
        _ operation: @escaping @MainActor () async -> Bool
    ) {
        guard !hasActiveTask else { return }
        let generation = UUID()
        metadataGeneration = generation
        metadataStopRequested = false
        metadataTask = Task { @MainActor in
            let saved = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await operation()
            }
            guard metadataGeneration == generation else { return }
            let wasStopped =
                metadataStopRequested || Task.isCancelled
            metadataTask = nil
            metadataStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    saved
                        ? "Document details finished updating before stopping · changes kept"
                        : "Document details update stopped"
                ).localizedUI
            }
        }
    }

    private var normalizedTagDraft: [String] {
        var seen: Set<String> = []
        return Array(
            tagText
                .split(separator: ",")
                .compactMap { value -> String? in
                    let trimmed = value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !trimmed.isEmpty else { return nil }
                    let shortened = String(trimmed.prefix(24))
                    guard seen.insert(
                        shortened.lowercased()
                    ).inserted else {
                        return nil
                    }
                    return shortened
                }
                .prefix(8)
        )
    }

    private var normalizedStoredTags: [String] {
        originalTags.map {
            $0.lowercased()
        }
    }

    private var hasTagChanges: Bool {
        normalizedTagDraft.map { $0.lowercased() }
            != normalizedStoredTags
    }

    private var tagSaveAccessibilityHint: String {
        if hasActiveTask {
            return "Wait for the current document update to finish."
                .localizedUI
        }
        if !hasTagChanges {
            return "The tag list is already saved.".localizedUI
        }
        return "Saves up to eight tags in PaperPath metadata."
            .localizedUI
    }

    private func pasteTags(_ value: String?) {
        guard let value else { return }
        let incoming = value
            .replacingOccurrences(of: "\r\n", with: ",")
            .replacingOccurrences(of: "\n", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return }
        let current = tagText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let combined = current.isEmpty
            ? incoming
            : "\(current), \(incoming)"
        tagText = String(combined.prefix(200))
    }

    private func saveTags(
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        guard !hasActiveTask else { return }
        guard hasTagChanges else {
            onSuccess?()
            return
        }
        let tags = normalizedTagDraft
        let generation = UUID()
        metadataGeneration = generation
        metadataStopRequested = false
        metadataTask = Task { @MainActor in
            let saved = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.updateTags(
                    recordID: recordID,
                    tags: tags,
                    expectedTags: originalTags
                )
            }
            guard metadataGeneration == generation else { return }
            let wasStopped =
                metadataStopRequested || Task.isCancelled
            metadataTask = nil
            metadataStopRequested = false
            if wasStopped {
                if saved {
                    synchronizeTagDraftWithCurrentRecord()
                }
                model[noticeFor: paperPathSceneID] = (
                    saved
                        ? "Tag update finished before stopping · changes kept"
                        : "Tag update stopped"
                ).localizedUI
                return
            }
            guard saved else { return }
            synchronizeTagDraftWithCurrentRecord()
            onSuccess?()
        }
    }

    private func loadTagDraftIfNeeded(from record: DocumentRecord) {
        guard !didLoadTagDraft else { return }
        originalTags = record.tags
        tagText = record.tags.joined(separator: ", ")
        didLoadTagDraft = true
    }

    private func reloadTagDraft() {
        originalTags = model.record(id: recordID)?.tags ?? []
        tagText = originalTags.joined(separator: ", ")
        didLoadTagDraft = true
    }

    private func synchronizeTagDraftWithCurrentRecord() {
        originalTags = model.record(id: recordID)?.tags ?? []
        tagText = originalTags.joined(separator: ", ")
    }

    private func performAfterSavingTags(
        expectedContentRevisionID: UUID,
        _ action: @escaping @MainActor () -> Void
    ) {
        guard !hasActiveTask else { return }
        let guardedAction = {
            guard model.record(id: recordID)?
                    .contentRevisionID
                    == expectedContentRevisionID
            else {
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                return
            }
            action()
        }
        if hasTagChanges {
            saveTags(onSuccess: guardedAction)
        } else {
            guardedAction()
        }
    }

    private func requestDismissal() {
        if hasTagChanges {
            isConfirmingTagDiscard = true
        } else {
            dismiss()
        }
    }

    private var hasActiveTask: Bool {
        analysisTask != nil || metadataTask != nil
    }

    private func retryAnalysis() {
        guard analysisTask == nil,
              model.record(id: recordID) != nil
        else { return }
        analysisErrorMessage = nil
        let generation = UUID()
        analysisGeneration = generation
        analysisTask = Task { @MainActor in
            await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.ensureAnalysisLoaded(for: recordID)
            }
            guard !Task.isCancelled,
                  analysisGeneration == generation
            else { return }
            analysisTask = nil
            if model.record(id: recordID)?.brief == nil {
                analysisErrorMessage =
                    "The document brief could not be created. Try again."
                analysisErrorFeedback += 1
            }
        }
    }

    private func interruptAnalysis() {
        analysisGeneration = UUID()
        analysisTask?.cancel()
        analysisTask = nil
    }

    private func interruptActiveWork() {
        if metadataTask != nil {
            interruptMetadataUpdate()
        } else {
            interruptAnalysis()
        }
    }

    private func interruptProtectedBriefWork() {
        interruptAnalysis()
        interruptMetadataUpdate(invalidateResult: true)
    }

    private func interruptMetadataUpdate(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            metadataGeneration = UUID()
            metadataStopRequested = false
        } else {
            guard metadataTask != nil,
                  !metadataStopRequested
            else { return }
            metadataStopRequested = true
        }
        metadataTask?.cancel()
        if invalidateResult {
            metadataTask = nil
        }
    }
}
