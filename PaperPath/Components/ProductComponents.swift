import SwiftUI

struct SectionEyebrow: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text.localizedUI)
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A compact map of the existing privacy flow; the model owns completion.
struct PrivacyWorkflowTrail: View {
    let stage: Int
    var onInk = false

    private let titles = ["Scan", "Review", "Verified"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(titles.indices, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(onInk ? PPColor.onInkSecondary : PPColor.border)
                        .frame(maxWidth: 24)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 5) {
                    Image(systemName: index < stage ? "checkmark.circle.fill" : "\(index + 1).circle\(index == stage ? ".fill" : "")")
                        .font(.caption.weight(.semibold))
                    Text(titles[index].localizedUI)
                        .font(.caption.weight(index == stage ? .semibold : .regular))
                        .lineLimit(1)
                }
                .foregroundStyle(
                    onInk
                        ? (index == stage ? PPColor.inkAccent : PPColor.onInkSecondary)
                        : (index == stage ? PPColor.accent : PPColor.textSecondary)
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == stage ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PPPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: PPRadius.control)
                        .fill(PPColor.textPrimary.opacity(0.05))
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : PPMotion.press, value: configuration.isPressed)
    }
}

struct OfficeClockContinuitySection: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if hasRollback(at: context.date) {
                OfficeClockContinuityNotice()
            }
        }
    }

    private func hasRollback(at wallDate: Date) -> Bool {
        let anchor = PDFOfficeTimeAnchor.process
        let systemUptime = ProcessInfo.processInfo.systemUptime
        _ = anchor.trustedDate(
            wallDate: wallDate,
            systemUptime: systemUptime
        )
        return anchor.hasWallClockRollback(
            wallDate: wallDate,
            systemUptime: systemUptime
        )
    }
}

struct OfficeClockContinuityNotice: View {
    var body: some View {
        Label(
            "System time moved backward. Expiry checks remain monotonic; new signed evidence is paused."
                .localizedUI,
            systemImage: "clock.badge.exclamationmark"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.amber)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "System time moved backward. Existing signature integrity is unchanged. Expiry checks use PaperPath’s latest observed time, and new signed evidence is paused until the clock catches up."
                .localizedUI
        )
        .accessibilityHint(
            "Correct the system date and time before creating new signed evidence."
                .localizedUI
        )
    }
}

struct DocumentKindBadge: View {
    let kind: DocumentKind

    var color: Color {
        switch kind {
        case .text: return PPColor.cyan
        case .scan: return PPColor.amber
        case .mixed: return PPColor.accent
        case .form: return PPColor.mint
        case .protected: return PPColor.textSecondary
        }
    }

    var body: some View {
        Label(kind.title.localizedUI, systemImage: kind.symbol)
            .font(.caption.smallCaps().weight(.semibold))
            .foregroundStyle(color)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(color.opacity(0.48))
                    .frame(height: 1)
            }
    }
}

struct PrivacyProof: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(alignment: .leading, spacing: PPSpacing.medium) {
                    privacySeal
                    proof(
                        "PDF stays local",
                        symbol: "iphone",
                        alignment: .leading
                    )
                    proof(
                        "No account",
                        symbol: "person.crop.circle.badge.xmark",
                        alignment: .leading
                    )
                    proof(
                        "Original safe",
                        symbol: "doc.badge.ellipsis",
                        alignment: .leading
                    )
                }
                .padding(.vertical, PPSpacing.medium)
            } else {
                HStack(spacing: PPSpacing.medium) {
                    privacySeal
                    proof("PDF stays local", symbol: "iphone")
                    separator
                    proof("No account", symbol: "person.crop.circle.badge.xmark")
                    separator
                    proof("Original safe", symbol: "doc.badge.ellipsis")
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .combine)
    }

    private var privacySeal: some View {
        ZStack {
            Circle()
                .stroke(PPColor.mint.opacity(0.7), lineWidth: 1)
            Circle()
                .stroke(
                    PPColor.mint.opacity(0.28),
                    style: StrokeStyle(lineWidth: 0.7, dash: [2, 2])
                )
                .padding(4)
            Image(systemName: "lock.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.mint)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func proof(
        _ title: String,
        symbol: String,
        alignment: Alignment = .center
    ) -> some View {
        Label(title.localizedUI, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(PPColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var separator: some View {
        Rectangle()
            .fill(PPColor.border.opacity(0.65))
            .frame(width: 0.5, height: 20)
    }
}

struct DocumentFan: View {
    @AppStorage("privacy.hideLibraryPreviews")
    private var hideLibraryPreviews = false

    let records: [DocumentRecord]
    let urlFor: (UUID) -> URL?
    let refreshTokenFor: (UUID) -> Int

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.12))
                .frame(width: 152, height: 30)
                .blur(radius: 11)
                .offset(y: 58)

            ForEach(Array(records.prefix(3).enumerated()), id: \.element.id) {
                index,
                record in
                if !hideLibraryPreviews,
                   let url = urlFor(record.id) {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(PPColor.surface)
                            .frame(
                                width: previewWidth(for: index) + 5,
                                height: previewWidth(for: index) * 1.28 + 6
                            )
                            .offset(x: 3, y: 4)

                        PDFPageThumbnailView(
                            url: url,
                            pageIndex: 0,
                            refreshToken: refreshTokenFor(record.id),
                            width: previewWidth(for: index)
                        )

                        if index == 2 {
                            Text("\(record.profile.pageCount)")
                                .font(.caption2.bold())
                                .monospacedDigit()
                                .foregroundStyle(Color.white)
                                .frame(width: 25, height: 19)
                                .background(PPColor.accent)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 5,
                                        style: .continuous
                                    )
                                )
                                .offset(x: 1, y: 1)
                        }
                    }
                    .rotationEffect(.degrees(rotation(for: index)))
                    .offset(
                        x: offset(for: index).width,
                        y: offset(for: index).height
                    )
                    .shadow(color: .black.opacity(0.17), radius: 10, y: 6)
                    .accessibilityHidden(true)
                } else {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous
                        )
                        .fill(PPColor.surface)
                        VStack(spacing: 7) {
                            Image(
                                systemName: index == 2
                                    ? "lock.doc.fill"
                                    : "doc.fill"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                index == 2
                                    ? PPColor.mint
                                    : PPColor.textSecondary
                            )
                            VStack(spacing: 4) {
                                ForEach(0..<3, id: \.self) { line in
                                    Rectangle()
                                        .fill(
                                            PPColor.border.opacity(0.7)
                                        )
                                        .frame(
                                            width: 42
                                                - CGFloat(line * 5),
                                            height: 1.5
                                        )
                                }
                            }
                        }
                    }
                    .frame(
                        width: previewWidth(for: index),
                        height: previewWidth(for: index) * 1.28
                    )
                    .rotationEffect(.degrees(rotation(for: index)))
                    .offset(
                        x: offset(for: index).width,
                        y: offset(for: index).height
                    )
                    .shadow(
                        color: .black.opacity(0.14),
                        radius: 8,
                        y: 5
                    )
                    .accessibilityHidden(true)
                }
            }

            annotationPencil
                .offset(x: 20, y: 64)

            binderClip
                .offset(x: -54, y: -60)

            localStamp
                .offset(x: 56, y: 38)
        }
        .frame(width: 184, height: 156)
        .dynamicTypeSize(.xSmall ... .large)
        .accessibilityHidden(true)
    }

    private var annotationPencil: some View {
        Canvas { context, size in
            let body = CGRect(
                x: 8,
                y: size.height * 0.44,
                width: size.width - 17,
                height: 8
            )
            context.fill(
                Path(roundedRect: body, cornerRadius: 3),
                with: .color(PPColor.amber)
            )
            context.fill(
                Path(
                    CGRect(
                        x: body.minX + 8,
                        y: body.minY,
                        width: 5,
                        height: body.height
                    )
                ),
                with: .color(Color.white.opacity(0.28))
            )
            let nib = Path { path in
                path.move(to: CGPoint(x: size.width - 9, y: body.minY))
                path.addLine(
                    to: CGPoint(x: size.width, y: body.midY)
                )
                path.addLine(
                    to: CGPoint(x: size.width - 9, y: body.maxY)
                )
                path.closeSubpath()
            }
            context.fill(nib, with: .color(PPColor.textSecondary))
        }
        .frame(width: 94, height: 22)
        .rotationEffect(.degrees(27))
        .accessibilityHidden(true)
    }

    private var binderClip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            PPColor.textPrimary.opacity(0.88),
                            PPColor.textSecondary.opacity(0.72)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 32, height: 19)
            Capsule()
                .stroke(PPColor.textPrimary.opacity(0.62), lineWidth: 1.4)
                .frame(width: 13, height: 24)
                .offset(x: -9, y: -9)
            Capsule()
                .stroke(PPColor.textPrimary.opacity(0.62), lineWidth: 1.4)
                .frame(width: 13, height: 24)
                .offset(x: 9, y: -9)
        }
        .rotationEffect(.degrees(-8))
        .accessibilityHidden(true)
    }

    private var localStamp: some View {
        Text("LOCAL")
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(PPColor.mint.opacity(0.78))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(PPColor.mint.opacity(0.58), lineWidth: 0.8)
            }
            .rotationEffect(.degrees(-8))
    }

    private func previewWidth(for index: Int) -> CGFloat {
        index == 2 ? 96 : 86
    }

    private func rotation(for index: Int) -> Double {
        switch index {
        case 0: return -11
        case 1: return 9
        default: return -1
        }
    }

    private func offset(for index: Int) -> CGSize {
        switch index {
        case 0: return CGSize(width: -37, height: 9)
        case 1: return CGSize(width: 35, height: 12)
        default: return CGSize(width: -2, height: -7)
        }
    }
}

struct PaperScanIllustration: View {
    var body: some View {
        Canvas { context, size in
            let backPaper = CGRect(
                x: size.width * 0.12,
                y: size.height * 0.17,
                width: size.width * 0.58,
                height: size.height * 0.72
            )
            context.addFilter(
                .shadow(
                    color: Color.black.opacity(0.11),
                    radius: 7,
                    x: 0,
                    y: 4
                )
            )
            context.fill(
                Path(roundedRect: backPaper, cornerRadius: 7),
                with: .color(PPColor.elevated)
            )

            let paper = CGRect(
                x: size.width * 0.24,
                y: size.height * 0.06,
                width: size.width * 0.64,
                height: size.height * 0.82
            )
            context.addFilter(
                .shadow(
                    color: Color.black.opacity(0.18),
                    radius: 9,
                    x: 0,
                    y: 6
                )
            )
            context.fill(
                Path(
                    roundedRect: paper,
                    cornerRadius: 8
                ),
                with: .color(Color.white)
            )

            context.addFilter(.shadow(color: .clear, radius: 0))

            let clip = Path { path in
                path.move(
                    to: CGPoint(
                        x: paper.minX + 14,
                        y: paper.minY + 30
                    )
                )
                path.addCurve(
                    to: CGPoint(
                        x: paper.minX + 31,
                        y: paper.minY + 15
                    ),
                    control1: CGPoint(
                        x: paper.minX + 4,
                        y: paper.minY + 12
                    ),
                    control2: CGPoint(
                        x: paper.minX + 24,
                        y: paper.minY + 3
                    )
                )
                path.addCurve(
                    to: CGPoint(
                        x: paper.minX + 38,
                        y: paper.minY + 31
                    ),
                    control1: CGPoint(
                        x: paper.minX + 41,
                        y: paper.minY + 15
                    ),
                    control2: CGPoint(
                        x: paper.minX + 48,
                        y: paper.minY + 28
                    )
                )
            }
            context.stroke(
                clip,
                with: .color(PPColor.textSecondary.opacity(0.72)),
                lineWidth: 1.5
            )

            let fold = Path { path in
                path.move(
                    to: CGPoint(x: paper.maxX - 28, y: paper.minY)
                )
                path.addLine(
                    to: CGPoint(x: paper.maxX, y: paper.minY + 28)
                )
                path.addLine(
                    to: CGPoint(x: paper.maxX - 28, y: paper.minY + 28)
                )
                path.closeSubpath()
            }
            context.fill(fold, with: .color(PPColor.surfaceMuted))

            for index in 0..<6 {
                let y = paper.minY + 46 + CGFloat(index) * 12
                var line = Path()
                line.move(to: CGPoint(x: paper.minX + 18, y: y))
                line.addLine(
                    to: CGPoint(
                        x: paper.maxX - (
                            index == 1 || index == 4 ? 38 : 18
                        ),
                        y: y
                    )
                )
                context.stroke(
                    line,
                    with: .color(PPColor.textSecondary.opacity(0.36)),
                    lineWidth: index == 0 ? 4 : 2
                )
            }

            let checkBox = CGRect(
                x: paper.minX + 18,
                y: paper.maxY - 24,
                width: 10,
                height: 10
            )
            context.stroke(
                Path(roundedRect: checkBox, cornerRadius: 2),
                with: .color(PPColor.mint.opacity(0.8)),
                lineWidth: 1.2
            )
            let check = Path { path in
                path.move(
                    to: CGPoint(
                        x: checkBox.minX + 2,
                        y: checkBox.midY
                    )
                )
                path.addLine(
                    to: CGPoint(
                        x: checkBox.midX - 1,
                        y: checkBox.maxY - 2
                    )
                )
                path.addLine(
                    to: CGPoint(
                        x: checkBox.maxX - 1,
                        y: checkBox.minY + 2
                    )
                )
            }
            context.stroke(
                check,
                with: .color(PPColor.mint),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )

            let beamY = paper.midY + 18
            let beam = CGRect(
                x: paper.minX - 14,
                y: beamY,
                width: paper.width + 28,
                height: 3
            )
            context.fill(
                Path(roundedRect: beam, cornerRadius: 2),
                with: .linearGradient(
                    Gradient(colors: [
                        .clear,
                        PPColor.cyan,
                        .clear
                    ]),
                    startPoint: CGPoint(x: beam.minX, y: beam.midY),
                    endPoint: CGPoint(x: beam.maxX, y: beam.midY)
                )
            )

            let lensCenter = CGPoint(
                x: size.width * 0.2,
                y: size.height * 0.7
            )
            let lensRect = CGRect(
                x: lensCenter.x - 19,
                y: lensCenter.y - 19,
                width: 38,
                height: 38
            )
            context.fill(
                Path(ellipseIn: lensRect),
                with: .color(PPColor.cyan.opacity(0.12))
            )
            context.stroke(
                Path(ellipseIn: lensRect),
                with: .color(PPColor.cyan.opacity(0.8)),
                lineWidth: 2
            )
            var handle = Path()
            handle.move(
                to: CGPoint(
                    x: lensCenter.x + 13,
                    y: lensCenter.y + 13
                )
            )
            handle.addLine(
                to: CGPoint(
                    x: lensCenter.x + 31,
                    y: lensCenter.y + 31
                )
            )
            context.stroke(
                handle,
                with: .color(PPColor.cyan.opacity(0.8)),
                style: StrokeStyle(lineWidth: 4, lineCap: .round)
            )
        }
        .frame(width: 168, height: 138)
        .accessibilityHidden(true)
    }
}

struct TaskPathArtwork: View {
    let package: PDFTaskPackage
    let tint: Color
    var compact = false

    var body: some View {
        ZStack {
            paperStack
            packageMarks
        }
        .frame(
            width: compact ? 64 : 138,
            height: compact ? 64 : 112
        )
        .accessibilityHidden(true)
    }

    private var paperStack: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 5 : 8)
                .fill(PPColor.elevated)
                .frame(
                    width: compact ? 38 : 76,
                    height: compact ? 48 : 96
                )
                .rotationEffect(.degrees(-8))
                .offset(x: compact ? -7 : -17, y: compact ? 2 : 5)

            RoundedRectangle(cornerRadius: compact ? 5 : 8)
                .fill(PPColor.surface)
                .frame(
                    width: compact ? 42 : 82,
                    height: compact ? 52 : 102
                )
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 5 : 8)
                        .stroke(PPColor.border.opacity(0.58), lineWidth: 0.7)
                }
                .shadow(
                    color: .black.opacity(compact ? 0.08 : 0.13),
                    radius: compact ? 3 : 7,
                    y: compact ? 2 : 4
                )
        }
    }

    @ViewBuilder
    private var packageMarks: some View {
        switch package {
        case .prepareToSend:
            VStack(spacing: compact ? 4 : 8) {
                documentLines(count: compact ? 2 : 3)
                Image(systemName: "signature")
                    .font(compact ? .caption : .body)
                    .foregroundStyle(PPColor.amber)
                Image(systemName: "checkmark.shield.fill")
                    .font(compact ? .caption : .title3)
                    .foregroundStyle(tint)
                    .offset(x: compact ? 16 : 31, y: compact ? 4 : 8)
            }
        case .makeSearchable:
            VStack(spacing: compact ? 4 : 7) {
                documentLines(count: compact ? 2 : 4)
                Rectangle()
                    .fill(tint.opacity(0.72))
                    .frame(
                        width: compact ? 46 : 92,
                        height: compact ? 1.5 : 2
                    )
                    .shadow(color: tint.opacity(0.4), radius: 3)
                Image(systemName: "text.magnifyingglass")
                    .font(compact ? .caption : .title3)
                    .foregroundStyle(tint)
            }
        case .convertForWork:
            VStack(spacing: compact ? 4 : 7) {
                documentLines(count: compact ? 2 : 3)
                HStack(spacing: compact ? 3 : 6) {
                    Text("W")
                    Text("X")
                    Text("P")
                }
                .font(
                    compact
                        ? .caption2.weight(.bold)
                        : .caption.weight(.bold)
                )
                .foregroundStyle(tint)
                Image(systemName: "arrow.up.right")
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
        case .compressForEmail:
            HStack(spacing: compact ? 1 : 3) {
                Image(systemName: "arrow.right")
                VStack(spacing: 1) {
                    Text("PDF")
                    Text("KB")
                        .foregroundStyle(tint)
                }
                Image(systemName: "arrow.left")
            }
            .font(
                compact
                    ? .caption2.weight(.bold)
                    : .caption.weight(.bold)
            )
            .monospacedDigit()
            .foregroundStyle(PPColor.textSecondary)
        case .redactAndProve:
            VStack(spacing: compact ? 4 : 7) {
                documentLines(count: 2)
                RoundedRectangle(cornerRadius: 1)
                    .fill(PPColor.textPrimary)
                    .frame(
                        width: compact ? 31 : 58,
                        height: compact ? 5 : 8
                    )
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(PPColor.textPrimary)
                        .frame(
                            width: compact ? 18 : 34,
                            height: compact ? 5 : 8
                        )
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(tint)
                }
            }
        case .fixPages:
            HStack(spacing: compact ? -7 : -11) {
                ForEach(1...3, id: \.self) { page in
                    RoundedRectangle(cornerRadius: compact ? 3 : 5)
                        .fill(
                            page == 2
                                ? PPColor.surface
                                : PPColor.elevated
                        )
                        .overlay {
                            Text("\(page)")
                                .font(
                                    compact
                                        ? .caption2.bold()
                                        : .caption.bold()
                                )
                                .monospacedDigit()
                                .foregroundStyle(
                                    page == 2 ? tint : PPColor.textSecondary
                                )
                        }
                        .frame(
                            width: compact ? 24 : 42,
                            height: compact ? 34 : 62
                        )
                        .rotationEffect(
                            .degrees(page == 1 ? -8 : page == 3 ? 8 : 0)
                        )
                        .zIndex(page == 2 ? 2 : 1)
                }
            }
        }
    }

    private func documentLines(count: Int) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(PPColor.textSecondary.opacity(0.28))
                    .frame(
                        width: (compact ? 31 : 58)
                            - CGFloat(index.isMultiple(of: 2) ? 0 : 9),
                        height: compact ? 1.5 : 2
                    )
            }
        }
    }
}

struct TaskPackageButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let package: PDFTaskPackage
    let tint: Color
    var isFeatured = false
    var isGridTile = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isGridTile
                    && !dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: PPSpacing.small) {
                        TaskPathArtwork(
                            package: package,
                            tint: tint,
                            compact: true
                        )
                        .scaleEffect(0.56)
                        .frame(width: 36, height: 42)

                        VStack(alignment: .leading, spacing: 2) {
                            if isFeatured {
                                Text("RECOMMENDED")
                                    .font(.caption2.smallCaps().weight(.bold))
                                    .foregroundStyle(tint)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.76)
                            }

                            Text(package.title.localizedUI)
                                .font(.subheadline.weight(.semibold))
                                .fontDesign(.serif)
                                .foregroundStyle(PPColor.textPrimary)
                                .lineLimit(2)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )

                            Text(package.detail.localizedUI)
                                .font(.caption2)
                                .foregroundStyle(PPColor.textSecondary)
                                .lineLimit(2)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 76,
                        alignment: .topLeading
                    )
                    .padding(.horizontal, PPSpacing.small)
                    .padding(.vertical, 6)
                    .background(
                        isFeatured
                            ? tint.opacity(0.055)
                            : Color.clear
                    )
                    .overlay(alignment: .leading) {
                        if isFeatured {
                            Rectangle()
                                .fill(tint.opacity(0.78))
                                .frame(width: 2)
                                .padding(.vertical, 6)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.58))
                            .frame(height: 0.6)
                    }
                } else if isFeatured {
                    HStack(spacing: PPSpacing.medium) {
                        TaskPathArtwork(
                            package: package,
                            tint: tint,
                            compact: true
                        )
                        .scaleEffect(0.82)
                        .frame(width: 52, height: 52)

                        VStack(
                            alignment: .leading,
                            spacing: 2
                        ) {
                            SectionEyebrow(text: "RECOMMENDED PATH")
                            Text(package.title.localizedUI)
                                .font(.headline)
                                .fontDesign(.serif)
                                .foregroundStyle(PPColor.textPrimary)
                            Text(package.detail.localizedUI)
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(tint)
                            .frame(width: 28, height: 44)
                    }
                    .frame(minHeight: 64)
                    .padding(.horizontal, PPSpacing.medium)
                    .padding(.vertical, PPSpacing.small)
                    .background {
                        RoundedRectangle(
                            cornerRadius: 12,
                            style: .continuous
                        )
                        .fill(PPColor.surface)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(tint.opacity(0.76))
                                .frame(width: 3)
                                .padding(.vertical, PPSpacing.regular)
                        }
                    }
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 12,
                            style: .continuous
                        )
                        .stroke(
                            PPColor.border.opacity(0.52),
                            lineWidth: 0.6
                        )
                    }
                } else {
                    HStack(spacing: PPSpacing.medium) {
                        TaskPathArtwork(
                            package: package,
                            tint: tint,
                            compact: true
                        )
                        .scaleEffect(0.82)
                        .frame(width: 52, height: 52)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(package.title.localizedUI)
                                .font(.subheadline.weight(.semibold))
                                .fontDesign(.serif)
                                .foregroundStyle(PPColor.textPrimary)
                            Text(package.detail.localizedUI)
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: PPSpacing.small)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(tint)
                            .frame(width: 28, height: 44)
                    }
                    .frame(minHeight: 64)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.52))
                            .frame(height: 0.6)
                            .padding(.leading, 64)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(package.title.localizedUI)
        .accessibilityHint(package.detail.localizedUI)
        .accessibilityValue(
            isFeatured ? "Recommended".localizedUI : ""
        )
        .accessibilityIdentifier("taskPackage-\(package.rawValue)")
    }
}

struct DocumentTaskShortcut: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recommendation: PDFTaskPackagePlanner.Recommendation
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(
                        alignment: .top,
                        spacing: PPSpacing.small
                    ) {
                        shortcutSymbol
                        VStack(
                            alignment: .leading,
                            spacing: 2
                        ) {
                            shortcutTitle
                            shortcutReason
                        }
                        Spacer(minLength: PPSpacing.xSmall)
                        shortcutDisclosure
                    }
                    .padding(.vertical, PPSpacing.xSmall)
                } else {
                    HStack(
                        alignment: .top,
                        spacing: PPSpacing.small
                    ) {
                        shortcutSymbol
                        VStack(
                            alignment: .leading,
                            spacing: 2
                        ) {
                            shortcutTitle
                            shortcutReason
                                .lineLimit(2)
                        }
                        Spacer(minLength: PPSpacing.small)
                        shortcutDisclosure
                    }
                    .padding(.vertical, PPSpacing.xSmall)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 48)
            .padding(.horizontal, PPSpacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            AppLocalization.format(
                "Next, %@",
                recommendation.title.localizedUI
            )
        )
        .accessibilityHint(recommendation.reason.localizedUI)
        .accessibilityIdentifier(
            "documentTask-\(recommendation.package.rawValue)"
        )
    }

    private var shortcutSymbol: some View {
        Image(systemName: recommendation.task.symbol)
            .font(.caption.weight(.semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 24)
    }

    private var shortcutTitle: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("NEXT")
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(PPColor.textSecondary)
            Text(recommendation.title.localizedUI)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(
                    dynamicTypeSize.isAccessibilitySize
                        ? nil
                        : 1
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutReason: some View {
        Text(recommendation.reason.localizedUI)
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var shortcutDisclosure: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .frame(minWidth: 20, minHeight: 44)
    }
}

struct ByteTelemetrySparkline: View {
    let samples: [Double]
    let isStalled: Bool

    var body: some View {
        Canvas { context, size in
            let values = Array(samples.suffix(24))
            guard values.count > 1 else {
                var baseline = Path()
                baseline.move(
                    to: CGPoint(x: 0, y: size.height / 2)
                )
                baseline.addLine(
                    to: CGPoint(
                        x: size.width,
                        y: size.height / 2
                    )
                )
                context.stroke(
                    baseline,
                    with: .color(PPColor.border),
                    lineWidth: 1
                )
                return
            }
            let lower = values.min() ?? 0
            let upper = values.max() ?? 0
            let spread = max(1, upper - lower)
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width
                    * CGFloat(index)
                    / CGFloat(max(1, values.count - 1))
                let normalized = (value - lower) / spread
                let y = size.height
                    - CGFloat(normalized) * (size.height - 2) - 1
                let point = CGPoint(x: x, y: y)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            context.stroke(
                path,
                with: .color(
                    isStalled ? PPColor.amber : PPColor.cyan
                ),
                style: StrokeStyle(
                    lineWidth: 1.5,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        .frame(width: 68, height: 20)
        .accessibilityElement()
        .accessibilityLabel(
            (
                isStalled
                    ? "Byte activity stalled"
                    : "Recent byte throughput"
            ).localizedUI
        )
    }
}

struct LocalOperationProgressView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let progress: PDFOperationProgress

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1,
                paused: scenePhase != .active
                    || progress.byteStage == nil
                    || progress.fractionCompleted >= 1
            )
        ) { context in
            let isStalled = progress.isStalled(at: context.date)
            progressContent(isStalled: isStalled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    accessibilitySummary(isStalled: isStalled)
                )
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func progressContent(isStalled: Bool) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(alignment: .leading, spacing: 3) {
                    progressTitle
                    progressPercent
                }
            } else {
                HStack {
                    progressTitle
                    Spacer(minLength: PPSpacing.small)
                    progressPercent
                }
            }
            ProgressView(value: progress.fractionCompleted)
                .tint(PPColor.cyan)
            if progress.byteStage == nil {
                Label("ON DEVICE".localizedUI, systemImage: "iphone")
                    .font(.caption2.smallCaps().weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        operationByteMetrics(isStalled: isStalled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(
                        alignment: .leading,
                        spacing: 3
                    ) {
                        operationByteMetrics(isStalled: isStalled)
                    }
                }
            }
        }
    }

    private var progressTitle: some View {
        Text(progress.label.localizedUI)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PPColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    private var progressPercent: some View {
        Text("\(progress.percentCompleted)%")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(PPColor.cyan)
            .fixedSize()
    }

    @ViewBuilder
    private func operationByteMetrics(
        isStalled: Bool
    ) -> some View {
        Label(
            (progress.byteStage?.title ?? "ON DEVICE").localizedUI,
            systemImage: progress.byteStage?.symbol ?? "iphone"
        )
        .font(.caption2.smallCaps().weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        if let bytes = progress.byteSummary {
            Text(bytes)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
        }
        if isStalled {
            Text("0 B/s")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.amber)
        } else if let speed = progress.throughputSummary {
            Text(speed)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.cyan)
        }
        if !isStalled,
           let remaining = progress.remainingSummary {
            Label(remaining, systemImage: "clock")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        ByteTelemetrySparkline(
            samples: progress.throughputHistory,
            isStalled: isStalled
        )
        if isStalled {
            Label("Stalled".localizedUI, systemImage: "pause.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PPColor.amber)
        }
    }

    private func accessibilitySummary(isStalled: Bool) -> String {
        var parts = [
            progress.label.localizedUI,
            AppLocalization.format(
                "%lld percent",
                progress.percentCompleted
            )
        ]
        if let stage = progress.byteStage {
            parts.append(stage.title.localizedUI)
        } else {
            parts.append("On device".localizedUI)
        }
        if let bytes = progress.byteSummary {
            parts.append(bytes)
        }
        if isStalled {
            parts.append("Stalled".localizedUI)
            parts.append("0 B/s")
        } else if let speed = progress.throughputSummary {
            parts.append(speed)
        }
        if !isStalled, let remaining = progress.remainingSummary {
            parts.append(
                AppLocalization.format(
                    "%@ remaining",
                    remaining
                )
            )
        }
        return parts.joined(separator: ", ")
    }
}

struct LocalComparisonProgressView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let progress: PDFComparisonProgress
    var tint: Color = PPColor.cyan
    var compact = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: compact ? 5 : PPSpacing.small
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    stageLabel
                    Spacer(minLength: PPSpacing.small)
                    progressMetrics
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: PPSpacing.small) {
                        stageLabel
                        Spacer(minLength: PPSpacing.small)
                        percentLabel
                    }
                    if let pageSummary = progress.pageSummary {
                        Text(pageSummary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(PPColor.textSecondary)
                    }
                }
            }
            ProgressView(value: progress.fractionCompleted)
                .tint(tint)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var stageLabel: some View {
        Label(
            progress.stage.title.localizedUI,
            systemImage: progress.stage.symbol
        )
        .font(
            compact
                ? .caption.weight(.semibold)
                : .subheadline.weight(.semibold)
        )
        .foregroundStyle(PPColor.textPrimary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
    }

    private var progressMetrics: some View {
        HStack(spacing: PPSpacing.small) {
            if let pageSummary = progress.pageSummary {
                Text(pageSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
            }
            percentLabel
        }
    }

    private var percentLabel: some View {
        Text(
            AppLocalization.format(
                "%lld percent",
                progress.percentCompleted
            )
        )
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
    }

    private var accessibilitySummary: String {
        let stageAndPercent = AppLocalization.format(
            "%@, %lld percent",
            progress.stage.title.localizedUI,
            progress.percentCompleted
        )
        guard let pageSummary = progress.pageSummary else {
            return stageAndPercent
        }
        return "\(stageAndPercent), \(pageSummary)"
    }
}

struct DocumentRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("privacy.hideLibraryPreviews")
    private var hideLibraryPreviews = false
    let record: DocumentRecord
    var url: URL?
    var refreshToken = 0
    var isCompact = false
    var showsDisclosure = true

    var body: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                accessibilityLayout
            } else if isCompact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .padding(
            .vertical,
            isCompact && !dynamicTypeSize.ppPrefersExpandedLayout
                ? PPSpacing.xSmall
                : PPSpacing.small
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [
                record.displayName,
                record.profile.kind.title.localizedUI,
                record.subtitle,
                rowStateAccessibility
            ].joined(separator: ", ")
        )
    }

    private var regularLayout: some View {
        HStack(spacing: PPSpacing.medium) {
            documentIcon

            VStack(alignment: .leading, spacing: 5) {
                title
                metadata
            }

            Spacer(minLength: PPSpacing.small)
            if showsDisclosure {
                disclosure
            }
        }
    }

    private var accessibilityLayout: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            title
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: PPSpacing.medium) {
                metadata
                Spacer(minLength: 0)
                if showsDisclosure {
                    disclosure
                }
            }
        }
    }

    private var compactLayout: some View {
        HStack(spacing: PPSpacing.small) {
            documentIcon

            VStack(alignment: .leading, spacing: 3) {
                title
                HStack(spacing: PPSpacing.small) {
                    if record.deliveryReceipt != nil {
                        Text(
                            (
                                record.hasCurrentDeliveryReceipt
                                    ? "Verified"
                                    : "Recheck"
                            ).localizedUI
                        )
                        .fontWeight(.semibold)
                        .foregroundStyle(
                            record.hasCurrentDeliveryReceipt
                                ? PPColor.mint
                                : PPColor.amber
                        )
                    }
                    Text(record.subtitle)
                        .monospacedDigit()
                    if let officeReceipt = record.officeReceipts.first {
                        Text(officeReceipt.format.fileExtension.uppercased())
                            .fontWeight(.semibold)
                            .foregroundStyle(PPColor.cyan)
                    }
                    if let tag = record.tags.first {
                        Text("#\(tag)")
                            .fontWeight(.semibold)
                            .foregroundStyle(PPColor.accent)
                    }
                    Text(record.workflowStatus.title.localizedUI)
                        .fontWeight(.semibold)
                }
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
            }

            Spacer(minLength: PPSpacing.small)
            if showsDisclosure {
                disclosure
            }
        }
    }

    private var documentIcon: some View {
        let usesCompactIcon = isCompact
            && !dynamicTypeSize.ppPrefersExpandedLayout
        let width: CGFloat = usesCompactIcon ? 40 : 56
        let height = width * 1.29

        return ZStack(alignment: .trailing) {
            if let url, !hideLibraryPreviews, !record.profile.isLocked {
                PDFPageThumbnailView(
                    url: url,
                    pageIndex: 0,
                    refreshToken: refreshToken,
                    width: width
                )
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(PPColor.surface)
                    Image(
                        systemName: hideLibraryPreviews ? "eye.slash"
                            : record.profile.isLocked ? "lock.doc" : record.profile.kind.symbol
                    )
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(PPColor.textSecondary)
                }
                .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4).stroke(PPColor.border.opacity(0.5), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var title: some View {
        Text(record.displayName)
            .font(PPType.document)
            .foregroundStyle(PPColor.textPrimary)
            .lineLimit(
                dynamicTypeSize.ppPrefersExpandedLayout ? nil : 2
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: some View {
        Text((record.brief?.summary ?? record.profile.summary).localizedUI)
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .lineLimit(
                dynamicTypeSize.ppPrefersExpandedLayout ? nil : 1
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var metadata: some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            metadataContent(axis: .vertical)
        } else {
            ViewThatFits(in: .horizontal) {
                metadataContent(axis: .horizontal)
                metadataContent(axis: .vertical)
            }
        }
    }

    private func metadataContent(axis: Axis) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: PPSpacing.small))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        return layout {
            Text(record.subtitle)
                .monospacedDigit()
            if let category = record.brief?.category {
                Text(category.title.localizedUI)
                    .foregroundStyle(PPColor.textSecondary)
            }
            if let tag = record.tags.first {
                Text("#\(tag)")
                    .fontWeight(.semibold)
                    .foregroundStyle(PPColor.accent)
            }
            if let dueAt = record.dueAt {
                Label(
                    dueTitle(dueAt),
                    systemImage: "calendar"
                )
                .fontWeight(.semibold)
                .foregroundStyle(dueTint(dueAt))
            }
            if record.deliveryReceipt != nil {
                Label(
                    (
                        record.hasCurrentDeliveryReceipt
                            ? "Verified"
                            : "Recheck"
                    ).localizedUI,
                    systemImage: record.hasCurrentDeliveryReceipt
                        ? "checkmark.seal"
                        : "arrow.triangle.2.circlepath"
                )
                .fontWeight(.semibold)
                .foregroundStyle(
                    record.hasCurrentDeliveryReceipt
                        ? PPColor.mint
                        : PPColor.amber
                )
            }
            if let officeReceipt = record.officeReceipts.first {
                Label(
                    officeReceipt.format.fileExtension.uppercased(),
                    systemImage: officeReceipt.format.symbol
                )
                .fontWeight(.semibold)
                .foregroundStyle(PPColor.cyan)
            }
            if record.profile.isLocked {
                Label("Locked", systemImage: "lock.doc")
                    .fontWeight(.semibold)
                    .foregroundStyle(PPColor.textSecondary)
            }
            if record.privateNote != nil {
                Image(systemName: "note.text")
                    .foregroundStyle(PPColor.amber)
                    .accessibilityLabel("Has private note")
            }
            Text(record.workflowStatus.title.localizedUI)
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .foregroundStyle(PPColor.textSecondary)
    }

    private var rowStateAccessibility: String {
        var parts: [String] = []
        if record.deliveryReceipt != nil {
            parts.append(
                (
                    record.hasCurrentDeliveryReceipt
                        ? "verified output is current"
                        : "delivery receipt needs recheck"
                ).localizedUI
            )
        }
        if let officeReceipt = record.officeReceipts.first {
            parts.append(
                AppLocalization.format(
                    "recent Office export %@",
                    officeReceipt.format.fileExtension.uppercased()
                )
            )
        }
        if record.profile.isLocked {
            parts.append("locked PDF".localizedUI)
        }
        return parts.isEmpty
            ? "local private copy".localizedUI
            : parts.joined(separator: ", ")
    }

    private var disclosure: some View {
        VStack(spacing: PPSpacing.small) {
            if record.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(PPColor.accent)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(PPColor.textSecondary.opacity(0.65))
        }
        .dynamicTypeSize(.xSmall ... .accessibility1)
    }

    private var kindColor: Color {
        switch record.profile.kind {
        case .text: return PPColor.cyan
        case .scan: return PPColor.amber
        case .mixed: return PPColor.accent
        case .form: return PPColor.mint
        case .protected: return PPColor.textSecondary
        }
    }

    private func dueTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today".localizedUI
        }
        if date < calendar.startOfDay(for: Date()) {
            return "Overdue".localizedUI
        }
        return date.formatted(
            .dateTime.month(.abbreviated).day()
        )
    }

    private func dueTint(_ date: Date) -> Color {
        let calendar = Calendar.current
        if date < calendar.startOfDay(for: Date()) {
            return .red
        }
        if calendar.isDateInToday(date) {
            return PPColor.amber
        }
        return PPColor.cyan
    }
}

struct ContextActionButton: View {
    let action: DocumentAction
    var isBusy = false
    let handler: () -> Void

    var body: some View {
        Button(action: handler) {
            VStack(spacing: 6) {
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: action.symbol)
                            .font(.body.weight(.semibold))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(height: 20)

                Text(action.title.localizedUI)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(
                action == .shareCopy ? PPColor.accent : PPColor.textPrimary
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(action.title.localizedUI)
        .accessibilityValue(
            isBusy ? "In progress".localizedUI : ""
        )
        .accessibilityHint(action.explanation.localizedUI)
    }
}

struct WorkspaceBarButton: View {
    let title: String
    let symbol: String
    var tint: Color = PPColor.textPrimary
    var isProminent = false
    let action: () -> Void
    @State private var feedback = 0

    var body: some View {
        Button {
            feedback += 1
            action()
        } label: {
            WorkspaceBarLabel(
                title: title,
                symbol: symbol,
                tint: tint,
                isProminent: isProminent
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .sensoryFeedback(.selection, trigger: feedback)
    }
}

struct WorkspaceBarLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let symbol: String
    var tint: Color = PPColor.textPrimary
    var isProminent = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(minHeight: 21)
            Text(title.localizedUI)
                .font(
                    .caption2.weight(
                        isProminent ? .bold : .semibold
                    )
                )
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                )
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .opacity(isEnabled ? 1 : 0.4)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 54)
        .background {
            if isProminent {
                RoundedRectangle(
                    cornerRadius: PPRadius.control,
                    style: .continuous
                )
                .fill(tint.opacity(0.1))
            }
        }
        .contentShape(Rectangle())
    }
}

struct ProfileMetric: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.7)
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol)
                    .foregroundStyle(PPColor.accent)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: PPSpacing.small)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textPrimary)
                    .contentTransition(.numericText())
            }
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PPSpacing.small)
    }
}

enum PPIllustrationKind {
    case intake
    case search
    case tools
    case locked
    case privacy
    case processing
    case workspace
}

struct PPIllustration: View {
    let kind: PPIllustrationKind
    var width: CGFloat = 188

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            atmosphere
            documentStack
            overlay
        }
        .frame(width: width, height: width * 0.82)
        .dynamicTypeSize(.xSmall ... .large)
        .accessibilityHidden(true)
    }

    private var atmosphere: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12))
                .frame(width: width * 0.8, height: width * 0.16)
                .blur(radius: width * 0.055)
                .offset(y: width * 0.33)

        }
    }

    private var documentStack: some View {
        ZStack {
            paperSheet(
                width: width * 0.42,
                height: width * 0.56,
                rotation: -10,
                offset: CGSize(width: -width * 0.2, height: width * 0.08),
                tint: secondaryTint.opacity(0.13)
            )
            paperSheet(
                width: width * 0.43,
                height: width * 0.58,
                rotation: 9,
                offset: CGSize(width: width * 0.18, height: width * 0.1),
                tint: primaryTint.opacity(0.1)
            )
            paperSheet(
                width: width * 0.47,
                height: width * 0.64,
                rotation: -1.5,
                offset: .zero,
                tint: .clear,
                isFront: true
            )
        }
    }

    private func paperSheet(
        width sheetWidth: CGFloat,
        height sheetHeight: CGFloat,
        rotation: Double,
        offset: CGSize,
        tint: Color,
        isFront: Bool = false
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PPColor.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint)
                }
                .overlay {
                    PaperGrain(opacity: 0.014)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 10,
                                style: .continuous
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(PPColor.border.opacity(0.52), lineWidth: 0.7)
                }

            if isFront {
                documentLines
                    .padding(.top, sheetHeight * 0.25)
                    .padding(.horizontal, sheetWidth * 0.16)

                brandPath
                    .frame(
                        width: sheetWidth * 0.7,
                        height: sheetHeight * 0.16
                    )
                    .padding(.top, sheetHeight * 0.66)

                Path { path in
                    path.move(to: CGPoint(x: sheetWidth - 26, y: 0))
                    path.addLine(to: CGPoint(x: sheetWidth, y: 26))
                    path.addLine(to: CGPoint(x: sheetWidth - 26, y: 26))
                    path.closeSubpath()
                }
                .fill(PPColor.surfaceMuted.opacity(0.85))
                .frame(width: sheetWidth, height: sheetHeight, alignment: .top)
            }
        }
        .frame(width: sheetWidth, height: sheetHeight)
        .rotationEffect(.degrees(rotation))
        .offset(offset)
        .shadow(
            color: .black.opacity(isFront ? 0.16 : 0.08),
            radius: isFront ? 12 : 7,
            y: isFront ? 7 : 4
        )
    }

    private var brandPath: some View {
        Canvas { context, size in
            var route = Path()
            route.move(
                to: CGPoint(x: size.width * 0.08, y: size.height * 0.34)
            )
            route.addCurve(
                to: CGPoint(x: size.width * 0.5, y: size.height * 0.7),
                control1: CGPoint(
                    x: size.width * 0.23,
                    y: size.height * 0.34
                ),
                control2: CGPoint(
                    x: size.width * 0.34,
                    y: size.height * 0.7
                )
            )
            route.addCurve(
                to: CGPoint(x: size.width * 0.92, y: size.height * 0.25),
                control1: CGPoint(
                    x: size.width * 0.68,
                    y: size.height * 0.7
                ),
                control2: CGPoint(
                    x: size.width * 0.75,
                    y: size.height * 0.25
                )
            )
            context.stroke(
                route,
                with: .color(PPColor.cyan.opacity(0.86)),
                style: StrokeStyle(
                    lineWidth: max(1.4, size.width * 0.045),
                    lineCap: .round,
                    lineJoin: .round
                )
            )

            let radius = max(2.2, size.width * 0.055)
            let checkpoints = [
                CGPoint(x: size.width * 0.08, y: size.height * 0.34),
                CGPoint(x: size.width * 0.5, y: size.height * 0.7),
                CGPoint(x: size.width * 0.92, y: size.height * 0.25)
            ]
            for checkpoint in checkpoints {
                let node = CGRect(
                    x: checkpoint.x - radius,
                    y: checkpoint.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(
                    Path(ellipseIn: node),
                    with: .color(PPColor.mint)
                )
            }
        }
        .accessibilityHidden(true)
    }

    private var documentLines: some View {
        VStack(alignment: .leading, spacing: width * 0.025) {
            Capsule()
                .fill(PPColor.textPrimary.opacity(0.18))
                .frame(width: width * 0.2, height: 5)
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(PPColor.textSecondary.opacity(index == 0 ? 0.22 : 0.16))
                    .frame(
                        width: width * (index == 2 ? 0.2 : 0.3),
                        height: index == 0 ? 3.5 : 2.5
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var overlay: some View {
        switch kind {
        case .intake:
            scanBeam
            cornerBadge("SCAN", tint: PPColor.cyan)
                .offset(x: width * 0.25, y: width * 0.2)
        case .search:
            magnifier
                .offset(x: -width * 0.23, y: width * 0.18)
            searchHit
                .offset(x: width * 0.18, y: -width * 0.18)
        case .tools:
            toolMosaic
                .offset(y: width * 0.17)
        case .locked:
            shieldBadge(symbol: "lock.fill", tint: PPColor.accent)
                .offset(x: width * 0.23, y: width * 0.12)
        case .privacy:
            shieldBadge(symbol: "checkmark", tint: PPColor.mint)
                .offset(x: width * 0.22, y: width * 0.13)
            cornerBadge("LOCAL", tint: PPColor.mint)
                .offset(x: -width * 0.24, y: -width * 0.22)
        case .processing:
            processingOrbit
        case .workspace:
            cornerBadge("READY", tint: PPColor.amber)
                .offset(x: width * 0.22, y: width * 0.19)
        }
    }

    private var scanBeam: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        PPColor.cyan.opacity(0.85),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width * 0.88, height: 4)
            .shadow(color: PPColor.cyan.opacity(0.35), radius: 8)
            .offset(y: width * 0.06)
    }

    private var magnifier: some View {
        ZStack {
            Circle()
                .fill(PPColor.surface.opacity(0.92))
            Circle()
                .fill(PPColor.cyan.opacity(0.1))
            Circle()
                .stroke(PPColor.cyan.opacity(0.82), lineWidth: 3)
            Capsule()
                .fill(PPColor.cyan.opacity(0.82))
                .frame(width: width * 0.16, height: 5)
                .rotationEffect(.degrees(42))
                .offset(x: width * 0.1, y: width * 0.1)
        }
        .frame(width: width * 0.26, height: width * 0.26)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    private var searchHit: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule()
                .fill(PPColor.cyan.opacity(0.3))
                .frame(width: width * 0.2, height: 6)
            Capsule()
                .fill(PPColor.amber.opacity(0.32))
                .frame(width: width * 0.15, height: 6)
        }
        .padding(8)
        .background(PPColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(PPColor.border.opacity(0.5), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.1), radius: 7, y: 4)
    }

    private var toolMosaic: some View {
        HStack(spacing: width * 0.025) {
            ToolSymbolPlate(
                symbol: "square.grid.2x2",
                tint: PPColor.accent,
                size: width * 0.22
            )
            .offset(y: -width * 0.035)
            ToolSymbolPlate(
                symbol: "signature",
                tint: PPColor.amber,
                size: width * 0.24
            )
            ToolSymbolPlate(
                symbol: "checkmark.shield",
                tint: PPColor.mint,
                size: width * 0.22
            )
            .offset(y: -width * 0.035)
        }
    }

    private func cornerBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(PPColor.surface.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(tint.opacity(0.52), lineWidth: 0.75)
            }
            .rotationEffect(.degrees(-7))
            .shadow(color: .black.opacity(0.09), radius: 5, y: 3)
    }

    private func shieldBadge(symbol: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(colorScheme == .dark ? 0.2 : 0.12))
            Circle()
                .stroke(tint.opacity(0.42), lineWidth: 1)
            Image(systemName: symbol)
                .font(.title3.weight(.bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
        .frame(width: width * 0.28, height: width * 0.28)
        .background(.regularMaterial, in: Circle())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    private var processingOrbit: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(
                    AngularGradient(
                        colors: [
                            primaryTint.opacity(0.1),
                            primaryTint.opacity(0.75),
                            secondaryTint.opacity(0.55),
                            primaryTint.opacity(0.1)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(
                        lineWidth: 3,
                        lineCap: .round,
                        dash: [7, 5]
                    )
                )
                .rotationEffect(.degrees(reduceMotion ? -12 : 28))
            Image(systemName: "gearshape.2")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(primaryTint)
        }
        .frame(width: width * 0.42, height: width * 0.42)
        .offset(x: width * 0.21, y: width * 0.16)
    }

    private var primaryTint: Color {
        switch kind {
        case .intake, .search, .tools:
            return PPColor.cyan
        case .locked, .workspace:
            return PPColor.accent
        case .privacy:
            return PPColor.mint
        case .processing:
            return PPColor.amber
        }
    }

    private var secondaryTint: Color {
        switch kind {
        case .intake, .processing:
            return PPColor.amber
        case .search, .workspace:
            return PPColor.mint
        case .tools, .locked, .privacy:
            return PPColor.accent
        }
    }
}

struct ToolSymbolPlate: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.09))
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct WorkflowMetric: Identifiable {
    let id: String
    let value: String
    let label: String
    let symbol: String
    let tint: Color

    init(
        id: String? = nil,
        value: String,
        label: String,
        symbol: String,
        tint: Color
    ) {
        self.id = id ?? "\(label)-\(value)"
        self.value = value
        self.label = label
        self.symbol = symbol
        self.tint = tint
    }
}

struct WorkflowCommandHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let eyebrow: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let metrics: [WorkflowMetric]
    var showsOnDevice = false

    var body: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(alignment: .top, spacing: PPSpacing.medium) {
                ToolSymbolPlate(
                    symbol: symbol,
                    tint: tint,
                    size: 42
                )

                VStack(alignment: .leading, spacing: 2) {
                    if usesCompactHeader {
                        HStack(spacing: PPSpacing.small) {
                            SectionEyebrow(text: eyebrow)
                            Spacer(minLength: PPSpacing.xSmall)
                            if showsOnDevice,
                               !dynamicTypeSize.ppPrefersExpandedLayout {
                                OnDeviceBadge(compact: true)
                            }
                        }
                    } else {
                        SectionEyebrow(text: eyebrow)
                    }
                    Text(title.localizedUI)
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? nil
                                : usesCompactHeader ? 2 : 1
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail.localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? nil
                                : usesCompactHeader ? 3 : 1
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsOnDevice,
                   !dynamicTypeSize.ppPrefersExpandedLayout,
                   !usesCompactHeader {
                    OnDeviceBadge(compact: true)
                }
            }

            if !metrics.isEmpty {
                LazyVGrid(
                    columns: metricColumns,
                    spacing: PPSpacing.medium
                ) {
                    ForEach(metrics) { metric in
                        StudioMetricCell(
                            value: metric.value,
                            label: metric.label,
                            symbol: metric.symbol,
                            tint: metric.tint
                        )
                    }
                }
            }
        }
        .padding(.bottom, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.6)
        }
    }

    private var usesCompactHeader: Bool {
        horizontalSizeClass == .compact
    }

    private var metricColumns: [GridItem] {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            return [
                GridItem(
                    .flexible(),
                    spacing: PPSpacing.medium
                )
            ]
        }
        return [
            GridItem(
                .adaptive(
                    minimum: usesCompactHeader ? 136 : 104,
                    maximum: 220
                ),
                spacing: PPSpacing.medium
            )
        ]
    }
}

struct OperationBoundaryNotice: View {
    let title: String
    let detail: String
    let identifier: String
    var symbol = "exclamationmark.triangle.fill"
    var tint = PPColor.amber

    var body: some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(detail.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, PPSpacing.small)
        .padding(.vertical, PPSpacing.xSmall)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(0.78))
                .frame(width: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

struct StudioMetricCell: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let value: String
    let label: String
    let symbol: String
    let tint: Color
    var detail: String?
    var allowsLabelWrapping = false

    var body: some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(value.localizedUI)
                    .font(.subheadline.weight(.bold))
                    .fontDesign(.monospaced)
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout ? nil : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                Text(label.localizedUI.uppercased())
                    .font(.caption2.smallCaps().weight(.semibold))
                    .fontDesign(.monospaced)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? nil
                            : allowsLabelWrapping ? 2 : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout ? nil : 1
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, PPSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: detail == nil ? 34 : 42)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(0.72))
                .frame(width: 2)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StudioSectionRule: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    var detail: String?
    var symbol: String?
    var count: Int?
    var tint = PPColor.accent

    var body: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing: PPSpacing.small
                    ) {
                        sectionIdentity
                        Spacer(minLength: PPSpacing.small)
                        sectionCount
                    }
                    if let detail {
                        Text(detail.localizedUI)
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing: PPSpacing.small
                    ) {
                        sectionIdentity
                            .fixedSize(horizontal: true, vertical: false)
                        if let detail {
                            Text(detail.localizedUI)
                                .font(.caption2)
                                .foregroundStyle(PPColor.textSecondary)
                                .lineLimit(1)
                                .fixedSize(
                                    horizontal: true,
                                    vertical: false
                                )
                        }
                        sectionRule
                        sectionCount
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(
                            alignment: .firstTextBaseline,
                            spacing: PPSpacing.small
                        ) {
                            sectionIdentity
                                .fixedSize(
                                    horizontal: true,
                                    vertical: false
                                )
                            sectionRule
                            sectionCount
                        }
                        if let detail {
                            Text(detail.localizedUI)
                                .font(.caption2)
                                .foregroundStyle(PPColor.textSecondary)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                    }
                }
            }
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var sectionIdentity: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
        Text(title.localizedUI)
            .font(.caption.smallCaps().weight(.bold))
            .fontDesign(.monospaced)
            .foregroundStyle(PPColor.textPrimary)
    }

    private var sectionRule: some View {
        Rectangle()
            .fill(PPColor.border.opacity(0.58))
            .frame(height: 0.6)
    }

    @ViewBuilder
    private var sectionCount: some View {
        if let count {
            Text("\(count)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
    }
}

struct StudioStageMarks: View {
    var tint = PPColor.accent
    var inset: CGFloat = 10
    var arm: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            guard size.width > inset * 2,
                  size.height > inset * 2
            else { return }

            let left = inset
            let right = size.width - inset
            let top = inset
            let bottom = size.height - inset
            var marks = Path()

            marks.move(to: CGPoint(x: left, y: top + arm))
            marks.addLine(to: CGPoint(x: left, y: top))
            marks.addLine(to: CGPoint(x: left + arm, y: top))

            marks.move(to: CGPoint(x: right - arm, y: top))
            marks.addLine(to: CGPoint(x: right, y: top))
            marks.addLine(to: CGPoint(x: right, y: top + arm))

            marks.move(to: CGPoint(x: left, y: bottom - arm))
            marks.addLine(to: CGPoint(x: left, y: bottom))
            marks.addLine(to: CGPoint(x: left + arm, y: bottom))

            marks.move(to: CGPoint(x: right - arm, y: bottom))
            marks.addLine(to: CGPoint(x: right, y: bottom))
            marks.addLine(to: CGPoint(x: right, y: bottom - arm))

            context.stroke(
                marks,
                with: .color(tint.opacity(0.42)),
                style: StrokeStyle(
                    lineWidth: 0.8,
                    lineCap: .square
                )
            )

            for point in [
                CGPoint(x: left, y: size.height / 2),
                CGPoint(x: right, y: size.height / 2)
            ] {
                var tick = Path()
                tick.move(
                    to: CGPoint(x: point.x - 3, y: point.y)
                )
                tick.addLine(
                    to: CGPoint(x: point.x + 3, y: point.y)
                )
                context.stroke(
                    tick,
                    with: .color(PPColor.amber.opacity(0.52)),
                    lineWidth: 0.8
                )
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct WorkflowSectionHeader: View {
    let eyebrow: String
    let title: String
    var count: Int?
    var tint = PPColor.accent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PPSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                SectionEyebrow(text: eyebrow)
                Text(title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
            }
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
        }
    }
}

struct PrecisionPlacementRail: View {
    private enum HorizontalAnchor {
        case leading
        case center
        case trailing
    }

    private enum VerticalAnchor {
        case top
        case center
        case bottom
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var bounds: PDFNormalizedRect

    var tint = PPColor.accent
    var title = "Position"
    var margin = 0.04
    var showsDimensions = true
    @State private var placementFeedback = 0

    var body: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    placementIdentity
                    placementControls
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        placementIdentity
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        placementControls
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                        placementIdentity
                        placementControls
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityElement(children: .contain)
        .sensoryFeedback(
            .selection,
            trigger: placementFeedback
        )
    }

    private var placementIdentity: some View {
        HStack(spacing: PPSpacing.small) {
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)

            if showsDimensions {
                Text(
                    "\(Int(bounds.width * 100))×\(Int(bounds.height * 100))%"
                )
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var placementControls: some View {
        HStack(spacing: PPSpacing.xSmall) {
            anchorButton(
                "Top left",
                symbol: "arrow.up.left",
                horizontal: .leading,
                vertical: .top
            )
            anchorButton(
                "Top right",
                symbol: "arrow.up.right",
                horizontal: .trailing,
                vertical: .top
            )
            anchorButton(
                "Center",
                symbol: "scope",
                horizontal: .center,
                vertical: .center
            )
            anchorButton(
                "Bottom left",
                symbol: "arrow.down.left",
                horizontal: .leading,
                vertical: .bottom
            )
            anchorButton(
                "Bottom right",
                symbol: "arrow.down.right",
                horizontal: .trailing,
                vertical: .bottom
            )
        }
        .frame(
            maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                ? .infinity
                : nil,
            alignment: .trailing
        )
    }

    private func anchorButton(
        _ label: String,
        symbol: String,
        horizontal: HorizontalAnchor,
        vertical: VerticalAnchor
    ) -> some View {
        Button {
            place(horizontal: horizontal, vertical: vertical)
            placementFeedback &+= 1
        } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(PPColor.surfaceMuted.opacity(0.72))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 6,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.localizedUI)
    }

    private func place(
        horizontal: HorizontalAnchor,
        vertical: VerticalAnchor
    ) {
        let x: Double
        switch horizontal {
        case .leading:
            x = margin
        case .trailing:
            x = 1 - margin - bounds.width
        default:
            x = (1 - bounds.width) / 2
        }

        let y: Double
        switch vertical {
        case .top:
            y = margin
        case .bottom:
            y = 1 - margin - bounds.height
        default:
            y = (1 - bounds.height) / 2
        }

        bounds = PDFNormalizedRect(
            x: min(max(0, x), 1 - bounds.width),
            y: min(max(0, y), 1 - bounds.height),
            width: bounds.width,
            height: bounds.height
        )
    }
}

struct PPEmptyState: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let kind: PPIllustrationKind
    let title: String
    let message: String
    var maxWidth: CGFloat = 420

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: PPSpacing.medium) {
                    emptyIllustration
                    emptyCopy
                }
            } else {
                HStack(alignment: .top, spacing: PPSpacing.regular) {
                emptyIllustration
                emptyCopy
                    .multilineTextAlignment(.leading)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PPSpacing.large)
        .padding(.horizontal, PPSpacing.regular)
        .accessibilityElement(children: .combine)
    }

    private var emptyIllustration: some View {
        ToolSymbolPlate(
            symbol: emptySymbol,
            tint: emptyTint,
            size: 44
        )
    }

    private var emptySymbol: String {
        switch kind {
        case .intake: return "tray.and.arrow.down"
        case .search: return "magnifyingglass"
        case .tools: return "wrench.and.screwdriver"
        case .locked: return "lock.doc"
        case .privacy: return "lock.shield"
        case .processing: return "hourglass"
        case .workspace: return "folder"
        }
    }

    private var emptyTint: Color {
        switch kind {
        case .intake, .search:
            return PPColor.cyan
        case .tools, .workspace:
            return PPColor.accent
        case .locked:
            return PPColor.amber
        case .privacy:
            return PPColor.mint
        case .processing:
            return PPColor.rose
        }
    }

    private var emptyCopy: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Text(title.localizedUI)
                .font(.headline)
                .foregroundStyle(PPColor.textPrimary)
            Text(message.localizedUI)
                .font(.subheadline)
                .foregroundStyle(PPColor.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: maxWidth)
        }
    }
}

private struct DeskToolNamesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var deskToolNamesVisible: Bool {
        get { self[DeskToolNamesKey.self] }
        set { self[DeskToolNamesKey.self] = newValue }
    }
}

struct DeskToolLabel: View {
    @Environment(\.deskToolNamesVisible) private var showsToolName
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var captionHeight = 30
    let title: String
    let symbol: String
    var tint: Color = PPColor.accent
    var isProminent = false

    var body: some View {
        VStack(spacing: PPSpacing.xSmall) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(
                    width: PPDeskLayout.touchTarget,
                    height: PPDeskLayout.touchTarget
                )
                .foregroundStyle(isProminent ? PPColor.onAccent : tint)
                .background(isProminent ? tint : Color.clear)
                .clipShape(Circle())
            if showsToolName {
                Text(title.localizedUI)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(PPColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 88, alignment: .top)
                    .frame(minHeight: captionHeight, alignment: .top)
            }
        }
        .frame(width: showsToolName ? 88 : PPDeskLayout.touchTarget)
        .contentShape(Rectangle())
    }
}

struct DeskIconButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let symbol: String
    var tint: Color = PPColor.accent
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DeskToolLabel(
                title: title, symbol: symbol, tint: tint,
                isProminent: isProminent
            )
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(DeskPressButtonStyle())
        .hoverEffect(.highlight)
        .accessibilityLabel(title.localizedUI)
        .accessibilityShowsLargeContentViewer {
            Label(title.localizedUI, systemImage: symbol)
        }
        .help(title.localizedUI)
    }
}

private struct DeskPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(
                reduceMotion ? nil : PPMotion.press,
                value: configuration.isPressed
            )
    }
}
