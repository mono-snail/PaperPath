import SwiftUI

struct DocumentBriefView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let recordID: UUID
    let onStep: (SuggestedStep, Int?) -> Void

    @State private var tagText = ""
    @State private var copyCount = 0

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                if let record = model.record(id: recordID),
                   let brief = record.brief {
                    content(record: record, brief: brief)
                } else {
                    ContentUnavailableView(
                        "Brief unavailable",
                        systemImage: "list.bullet.rectangle.portrait",
                        description: Text("PaperPath has not indexed this document yet.")
                    )
                }
            }
            .navigationTitle("Document brief")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let record = model.record(id: recordID) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task {
                                await model.togglePinned(recordID: recordID)
                            }
                        } label: {
                            Image(
                                systemName: record.isPinned ? "pin.fill" : "pin"
                            )
                        }
                        .accessibilityLabel(
                            (
                                record.isPinned
                                    ? "Unpin"
                                    : "Pin"
                            ).localizedUI
                        )
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: copyCount)
    }

    private func content(
        record: DocumentRecord,
        brief: DocumentBrief
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPSpacing.large) {
                overview(record: record, brief: brief)
                workflow(record)
                if !brief.suggestedSteps.isEmpty {
                    suggestedSteps(brief.suggestedSteps, record: record)
                }
                if !brief.entities.isEmpty {
                    facts(brief.entities)
                }
                organization(record)
                fileDetails(record)
                indexEvidence(brief)
            }
            .frame(maxWidth: 920)
            .padding(PPSpacing.regular)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            tagText = record.tags.joined(separator: ", ")
        }
    }

    private func overview(
        record: DocumentRecord,
        brief: DocumentBrief
    ) -> some View {
        HStack(alignment: .center, spacing: PPSpacing.medium) {
            if horizontalSizeClass == .regular,
               !dynamicTypeSize.isAccessibilitySize {
                documentCover(record)
                    .scaleEffect(0.72)
                    .frame(width: 100, height: 126)
            }
            WorkflowCommandHeader(
                eyebrow: "DOCUMENT EVIDENCE",
                title: record.displayName,
                detail: brief.summary,
                symbol: brief.category.symbol,
                tint: confidenceColor(brief.resolvedConfidence),
                metrics: [
                    WorkflowMetric(
                        value: "\(brief.entities.count)",
                        label: "Facts",
                        symbol: "sparkle.magnifyingglass",
                        tint: PPColor.cyan
                    ),
                    WorkflowMetric(
                        value: "\(brief.suggestedSteps.count)",
                        label: "Steps",
                        symbol: "checklist",
                        tint: PPColor.accent
                    ),
                    WorkflowMetric(
                        value: "\(brief.indexedCharacterCount)",
                        label: "Characters",
                        symbol: "textformat",
                        tint: PPColor.mint
                    ),
                    WorkflowMetric(
                        value: brief.resolvedConfidence.title,
                        label: "Confidence",
                        symbol: brief.resolvedConfidence.symbol,
                        tint: confidenceColor(
                            brief.resolvedConfidence
                        )
                    )
                ]
            )
        }
    }

    private func compactOverview(
        record: DocumentRecord,
        brief: DocumentBrief
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.large) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: PPSpacing.large) {
                    documentCover(record)
                        .frame(maxWidth: .infinity)
                    overviewHeading(record: record, brief: brief)
                }
            } else {
                HStack(alignment: .top, spacing: PPSpacing.large) {
                    documentCover(record)
                    overviewHeading(record: record, brief: brief)
                }
            }

            Text(brief.summary.localizedUI)
                .font(.body)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            metricStrip(brief)
        }
    }

    private func overviewCopy(
        record: DocumentRecord,
        brief: DocumentBrief
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            overviewHeading(record: record, brief: brief)

            Text(brief.summary.localizedUI)
                .font(.body)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            metricStrip(brief)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overviewHeading(
        record: DocumentRecord,
        brief: DocumentBrief
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    categoryBadge(brief.category)
                    confidenceBadge(brief.resolvedConfidence)
                    Spacer(minLength: PPSpacing.small)
                    OnDeviceBadge(compact: true)
                }

                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    HStack(spacing: PPSpacing.small) {
                        categoryBadge(brief.category)
                        confidenceBadge(brief.resolvedConfidence)
                    }
                    OnDeviceBadge(compact: true)
                }
            }

            Text(record.displayName)
                .font(.title2.bold())
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricStrip(_ brief: DocumentBrief) -> some View {
        let metricLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: PPSpacing.medium))
            : AnyLayout(HStackLayout(spacing: PPSpacing.large))

        return metricLayout {
            compactMetric(
                "\(brief.entities.count)",
                label: "facts",
                symbol: "sparkle.magnifyingglass"
            )
            compactMetric(
                "\(brief.suggestedSteps.count)",
                label: "steps",
                symbol: "checklist"
            )
            compactMetric(
                "\(brief.indexedCharacterCount)",
                label: "characters",
                symbol: "textformat"
            )
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

    private func categoryBadge(_ category: DocumentCategory) -> some View {
        Label(category.title.localizedUI, systemImage: category.symbol)
            .font(.caption.smallCaps().weight(.semibold))
            .foregroundStyle(PPColor.accent)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.accent.opacity(0.5))
                    .frame(height: 1)
            }
            .lineLimit(1)
    }

    private func confidenceBadge(
        _ confidence: DocumentUnderstandingConfidence
    ) -> some View {
        Label(confidence.title.localizedUI, systemImage: confidence.symbol)
            .font(.caption2.smallCaps().weight(.semibold))
            .foregroundStyle(confidenceColor(confidence))
            .lineLimit(1)
            .accessibilityLabel(
                "Document type \(confidence.title.lowercased())"
            )
    }

    private func workflow(_ record: DocumentRecord) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: PPSpacing.medium))
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

        return VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "WORKFLOW")
            layout {
                Menu {
                    ForEach(DocumentWorkflowStatus.allCases) { status in
                        Button {
                            Task {
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

                if record.workflowStatus != .ready {
                    Button {
                        Task {
                            await model.updateWorkflow(
                                recordID: recordID,
                                status: .ready
                            )
                        }
                    } label: {
                        Label("Mark Ready", systemImage: "checkmark")
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
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
                        onStep(step, evidencePage(for: step))
                    } label: {
                        HStack(alignment: .top, spacing: PPSpacing.medium) {
                            VStack(spacing: 3) {
                                Image(
                                    systemName: isCompleted
                                        ? "checkmark.circle.fill"
                                        : step.kind.symbol
                                )
                                .font(.caption.weight(.semibold))
                                if !isCompleted {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.caption2.weight(.bold))
                                        .monospacedDigit()
                                }
                            }
                            .foregroundStyle(
                                isCompleted ? PPColor.mint : PPColor.accent
                            )
                            .frame(width: 34)
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(PPColor.border.opacity(0.64))
                                    .frame(width: 0.6, height: 40)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title.localizedUI)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(PPColor.textPrimary)
                                Text(step.evidence.localizedUI)
                                    .font(.caption)
                                    .foregroundStyle(PPColor.textSecondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                if isCompleted {
                                    Text("COMPLETED")
                                        .font(.caption2.smallCaps().weight(.bold))
                                        .foregroundStyle(PPColor.mint)
                                }
                            }
                            Spacer()
                            if let pageIndex = step.evidencePageIndex {
                                Text("p\(pageIndex + 1)")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(PPColor.textSecondary)
                            }
                            Image(
                                systemName: isCompleted
                                    ? "checkmark"
                                    : "arrow.up.right"
                            )
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PPColor.textSecondary)
                        }
                        .padding(.vertical, PPSpacing.medium)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

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

    private func facts(_ entities: [DetectedEntity]) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "DETECTED FACTS")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210), spacing: PPSpacing.medium)],
                spacing: PPSpacing.medium
            ) {
                ForEach(entities) { entity in
                    Button {
                        SecurePasteboard.copy(entity.value)
                        copyCount += 1
                        model.noticeMessage = "\(entity.kind.title) copied"
                    } label: {
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
                                    .lineLimit(2)
                            }
                            Spacer()
                            if let pageIndex = entity.pageIndex {
                                Text("p\(pageIndex + 1)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(PPColor.textSecondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, PPSpacing.medium)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(PPColor.border.opacity(0.62))
                                .frame(height: 0.6)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Copies this fact")
                }
            }
        }
    }

    private func organization(_ record: DocumentRecord) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: PPSpacing.medium))
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

        return VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "ORGANIZE")
            layout {
                TextField("contract, client", text: $tagText)
                    .textInputAutocapitalization(.never)
                    .font(.body)
                    .padding(PPSpacing.medium)
                    .background(PPColor.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button {
                    let tags = tagText.split(separator: ",").map(String.init)
                    Task {
                        await model.updateTags(recordID: recordID, tags: tags)
                    }
                } label: {
                    if dynamicTypeSize.isAccessibilitySize {
                        Label("Save Tags", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    } else {
                        Image(systemName: "checkmark")
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.mint))
                .accessibilityLabel("Save tags")
            }
            Text("Separate tags with commas. Tags are included in local search.")
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
        }
    }

    private func indexEvidence(_ brief: DocumentBrief) -> some View {
        HStack(spacing: PPSpacing.medium) {
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
                    "Source: \(brief.textSource?.rawValue ?? "metadata") · PDF content stays local"
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
            }
            Spacer()
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

    private func compactMetric(
        _ value: String,
        label: String,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
            Label(value.localizedUI, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PPColor.textPrimary)
            Text(label.localizedUI)
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
}
