import PDFKit
import SwiftUI

struct PDFDocumentView: UIViewRepresentable {
    let url: URL
    let refreshToken: Int
    let targetPageIndex: Int?
    let navigationToken: Int
    let readingPreferences: PDFReadingPreferences
    let command: PDFViewCommand?
    let evidenceOverlay: PDFEvidenceOverlay?
    let onMutation: () -> Void
    let onRedactionMarks: ([PDFRedactionMark]) -> Void
    let onTextSelection: (PDFTextSelectionSnapshot) -> Void
    let onPageChange: (Int) -> Void
    let onCommandMessage: (String) -> Void
    let unlockPassword: String?
    let onUnlock: (Bool) -> Void

    init(
        url: URL,
        refreshToken: Int,
        targetPageIndex: Int?,
        navigationToken: Int,
        readingPreferences: PDFReadingPreferences = PDFReadingPreferences(),
        command: PDFViewCommand? = nil,
        evidenceOverlay: PDFEvidenceOverlay? = nil,
        onMutation: @escaping () -> Void = {},
        onRedactionMarks: @escaping ([PDFRedactionMark]) -> Void = { _ in },
        onTextSelection: @escaping (
            PDFTextSelectionSnapshot
        ) -> Void = { _ in },
        onPageChange: @escaping (Int) -> Void = { _ in },
        onCommandMessage: @escaping (String) -> Void = { _ in },
        unlockPassword: String? = nil,
        onUnlock: @escaping (Bool) -> Void = { _ in }
    ) {
        self.url = url
        self.refreshToken = refreshToken
        self.targetPageIndex = targetPageIndex
        self.navigationToken = navigationToken
        self.readingPreferences = readingPreferences
        self.command = command
        self.evidenceOverlay = evidenceOverlay
        self.onMutation = onMutation
        self.onRedactionMarks = onRedactionMarks
        self.onTextSelection = onTextSelection
        self.onPageChange = onPageChange
        self.onCommandMessage = onCommandMessage
        self.unlockPassword = unlockPassword
        self.onUnlock = onUnlock
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displaysPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        applyReadingPreferences(to: view)
        context.coordinator.observePageChanges(in: view)
        load(
            into: view,
            coordinator: context.coordinator,
            preservingViewport: false
        )
        navigate(in: view, coordinator: context.coordinator)
        applyEvidenceOverlay(
            evidenceOverlay,
            in: view,
            coordinator: context.coordinator
        )
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        applyReadingPreferences(to: view)
        let needsReload = context.coordinator.url != url
            || context.coordinator.refreshToken != refreshToken
            || context.coordinator.unlockPassword != unlockPassword
        let shouldPreserveViewport = needsReload
            && context.coordinator.url == url
            && context.coordinator.unlockPassword == unlockPassword
            && context.coordinator.navigationToken == navigationToken
        let needsNavigation =
            context.coordinator.navigationToken != navigationToken
        let isSelfMutationRefresh = needsReload
            && context.coordinator.skipsNextSelfMutationReload
            && context.coordinator.url == url
            && context.coordinator.unlockPassword == unlockPassword
        if isSelfMutationRefresh {
            context.coordinator.skipsNextSelfMutationReload = false
            context.coordinator.refreshToken = refreshToken
        } else if needsReload {
            load(
                into: view,
                coordinator: context.coordinator,
                preservingViewport: shouldPreserveViewport
            )
        }
        if needsNavigation || (needsReload && !shouldPreserveViewport) {
            navigate(in: view, coordinator: context.coordinator)
        }
        if let command,
           context.coordinator.commandID != command.id {
            context.coordinator.commandID = command.id
            execute(command, in: view, coordinator: context.coordinator)
        }
        if needsReload
            || needsNavigation
            || context.coordinator.evidenceOverlay != evidenceOverlay {
            applyEvidenceOverlay(
                evidenceOverlay,
                in: view,
                coordinator: context.coordinator
            )
        }
    }

    static func dismantleUIView(
        _ view: PDFView,
        coordinator: Coordinator
    ) {
        coordinator.removeEvidenceAnnotations()
    }

    private func applyReadingPreferences(to view: PDFView) {
        switch readingPreferences.layout {
        case .continuous:
            view.displayMode = .singlePageContinuous
            view.usePageViewController(false)
        case .singlePage:
            view.displayMode = .singlePage
            view.usePageViewController(true)
        case .twoUp:
            view.displayMode = .twoUpContinuous
            view.usePageViewController(false)
        }
        view.displayDirection = readingPreferences.scrollsHorizontally
            ? .horizontal
            : .vertical
        switch readingPreferences.theme {
        case .paper:
            view.backgroundColor = .clear
        case .sepia:
            view.backgroundColor = UIColor(
                red: 0.92,
                green: 0.86,
                blue: 0.72,
                alpha: 1
            )
        case .night:
            view.backgroundColor = UIColor(
                red: 0.04,
                green: 0.055,
                blue: 0.075,
                alpha: 1
            )
        }
    }

    private func execute(
        _ command: PDFViewCommand,
        in view: PDFView,
        coordinator: Coordinator
    ) {
        switch command.action {
        case .markup(let kind):
            addMarkup(
                kind,
                color: command.markupColor,
                in: view,
                coordinator: coordinator
            )
        case .addNote(let text):
            addNote(text, in: view, coordinator: coordinator)
        case .markRedaction:
            captureRedactionMarks(in: view)
        case .captureTextForEditing:
            captureTextForEditing(in: view)
        case .removeAnnotation:
            removeAnnotation(in: view, coordinator: coordinator)
        }
    }

    private func addMarkup(
        _ kind: PDFMarkupKind,
        color selectedColor: PDFMarkupColor?,
        in view: PDFView,
        coordinator: Coordinator
    ) {
        guard let document = view.document,
              let selection = view.currentSelection,
              let selectedText = selection.string,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            onCommandMessage("Select text in the PDF first")
            return
        }

        let subtype: PDFAnnotationSubtype
        let color: UIColor
        switch kind {
        case .highlight:
            subtype = .highlight
            color = markupUIColor(
                selectedColor ?? .yellow,
                alpha: 0.48
            )
        case .underline:
            subtype = .underline
            color = markupUIColor(
                selectedColor ?? .blue,
                alpha: 0.82
            )
        case .strikeOut:
            subtype = .strikeOut
            color = markupUIColor(
                selectedColor ?? .red,
                alpha: 0.78
            )
        }

        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let bounds = line.bounds(for: page).insetBy(dx: -1, dy: -1)
            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: subtype,
                withProperties: nil
            )
            annotation.color = color
            annotation.contents = line.string
            annotation.shouldDisplay = true
            annotation.shouldPrint = true
            annotation.isReadOnly = true
            page.addAnnotation(annotation)
        }
        resetTextSelection(in: view)
        persist(document, coordinator: coordinator)
        onCommandMessage("Markup saved")
    }

    private func markupUIColor(
        _ color: PDFMarkupColor,
        alpha: CGFloat
    ) -> UIColor {
        let base: UIColor
        switch color {
        case .yellow: base = .systemYellow
        case .mint: base = .systemMint
        case .blue: base = .systemBlue
        case .pink: base = .systemPink
        case .red: base = .systemRed
        }
        return base.withAlphaComponent(alpha)
    }

    private func addNote(
        _ text: String,
        in view: PDFView,
        coordinator: Coordinator
    ) {
        guard let document = view.document,
              let page = view.currentPage,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            onCommandMessage("The note could not be placed")
            return
        }
        let pageBounds = page.bounds(for: .cropBox)
        let visibleCenter = CGPoint(
            x: pageBounds.midX - 16,
            y: pageBounds.midY - 16
        )
        let annotation = PDFAnnotation(
            bounds: CGRect(origin: visibleCenter, size: CGSize(width: 32, height: 32)),
            forType: .text,
            withProperties: nil
        )
        annotation.contents = text
        annotation.color = .systemOrange
        annotation.iconType = .comment
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        page.addAnnotation(annotation)
        persist(document, coordinator: coordinator)
        onCommandMessage("Note added to the current page")
    }

    private func captureRedactionMarks(in view: PDFView) {
        guard let document = view.document,
              let selection = view.currentSelection
        else { return }
        let marks = selection.selectionsByLine().compactMap { line -> PDFRedactionMark? in
            guard let page = line.pages.first else { return nil }
            let pageBounds = page.bounds(for: .cropBox)
            let bounds = line.bounds(for: page).intersection(pageBounds)
            guard pageBounds.width > 0,
                  pageBounds.height > 0,
                  !bounds.isNull
            else { return nil }
            return PDFRedactionMark(
                pageIndex: document.index(for: page),
                normalizedX: bounds.minX / pageBounds.width,
                normalizedY: bounds.minY / pageBounds.height,
                normalizedWidth: bounds.width / pageBounds.width,
                normalizedHeight: bounds.height / pageBounds.height
            )
        }
        view.clearSelection()
        onRedactionMarks(
            PDFRedactionMarkSanitizer.clean(marks)
        )
    }

    private func captureTextForEditing(in view: PDFView) {
        guard let document = view.document,
              let selection = view.currentSelection,
              (1...4).contains(selection.pages.count),
              let firstPage = selection.pages.min(by: {
                  document.index(for: $0) < document.index(for: $1)
              }),
              let selectedText = selection.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedText.isEmpty
        else {
            onCommandMessage("Select text across no more than four pages")
            return
        }
        let lines = selection.selectionsByLine()
        guard !lines.isEmpty, lines.count <= 96 else {
            onCommandMessage("Select up to 96 lines")
            return
        }
        let firstPageBounds = firstPage.bounds(for: .cropBox)
        let selectionBounds = selection.bounds(for: firstPage)
            .intersection(firstPageBounds)
        guard firstPageBounds.width > 0,
              firstPageBounds.height > 0,
              selectionBounds.width > 2,
              selectionBounds.height > 2
        else {
            onCommandMessage("The selected text has no editable bounds")
            return
        }

        let orderedPages = selection.pages.sorted {
            document.index(for: $0) < document.index(for: $1)
        }
        var flowRegions: [PDFTextFlowRegion] = []
        for page in orderedPages {
            let pageIndex = document.index(for: page)
            let pageBounds = page.bounds(for: .cropBox)
            guard pageBounds.width > 0,
                  pageBounds.height > 0
            else {
                onCommandMessage("One selected page has invalid bounds")
                return
            }
            let pageLines = lines.filter {
                guard let linePage = $0.pages.first else { return false }
                return document.index(for: linePage) == pageIndex
            }
            let pageFlows = textFlowBounds(
                for: pageLines,
                on: page,
                pageBounds: pageBounds
            )
            flowRegions.append(
                contentsOf: pageFlows.map {
                    PDFTextFlowRegion(
                        pageIndex: pageIndex,
                        normalizedX: (
                            $0.bounds.minX - pageBounds.minX
                        ) / pageBounds.width,
                        normalizedY: (
                            pageBounds.maxY - $0.bounds.maxY
                        ) / pageBounds.height,
                        normalizedWidth: $0.bounds.width
                            / pageBounds.width,
                        normalizedHeight: $0.bounds.height
                            / pageBounds.height,
                        lineCount: $0.lineCount,
                        originalText: $0.originalText,
                        sourceRangeLocation: $0.sourceRange?.location,
                        sourceRangeLength: $0.sourceRange?.length
                    )
                }
            )
        }
        guard !flowRegions.isEmpty, flowRegions.count <= 16 else {
            onCommandMessage("Select no more than sixteen text boxes")
            return
        }

        let attributed = selection.attributedString
        var fonts: [UIFont] = []
        var colors: [UIColor] = []
        var fontFamilyCounts: [String: Int] = [:]
        if let attributed, attributed.length > 0 {
            attributed.enumerateAttribute(
                .font,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, range, _ in
                if let font = value as? UIFont {
                    let weight = max(1, min(range.length, 32))
                    fonts.append(
                        contentsOf: repeatElement(
                            font,
                            count: weight
                        )
                    )
                    fontFamilyCounts[font.familyName, default: 0]
                        += range.length
                }
            }
            attributed.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, _, _ in
                if let color = value as? UIColor {
                    colors.append(color)
                }
            }
        }
        let significantFamilyThreshold = max(
            3,
            (fontFamilyCounts.values.reduce(0, +) + 9) / 10
        )
        let significantFamilyCount = fontFamilyCounts.values.filter {
            $0 >= significantFamilyThreshold
        }.count
        let fontSizes = fonts.map(\.pointSize).sorted()
        let fontSize = fontSizes.isEmpty
            ? selectionBounds.height
                / CGFloat(max(1, lines.count)) * 0.72
            : fontSizes[fontSizes.count / 2]
        let snapshot = PDFTextSelectionSnapshot(
            pageIndex: document.index(for: firstPage),
            originalText: selectedText,
            normalizedX: (
                selectionBounds.minX - firstPageBounds.minX
            ) / firstPageBounds.width,
            normalizedY: (
                firstPageBounds.maxY - selectionBounds.maxY
            ) / firstPageBounds.height,
            normalizedWidth: selectionBounds.width
                / firstPageBounds.width,
            normalizedHeight: selectionBounds.height
                / firstPageBounds.height,
            fontName: fonts.first?.fontName,
            fontSize: fontSize,
            color: pdfInkColor(colors.first ?? .black),
            lineCount: lines.count,
            hasMixedFonts: significantFamilyCount > 1,
            pageRotation: firstPage.rotation,
            flowRegions: flowRegions
        )
        view.clearSelection()
        onTextSelection(snapshot)
    }

    private func textFlowBounds(
        for lines: [PDFSelection],
        on page: PDFPage,
        pageBounds: CGRect
    ) -> [
        (
            bounds: CGRect,
            lineCount: Int,
            originalText: String,
            sourceRange: NSRange?
        )
    ] {
        let items = lines.compactMap {
            line -> (selection: PDFSelection, bounds: CGRect)? in
            let value = line.bounds(for: page).intersection(pageBounds)
            guard !value.isNull,
                  value.width > 2,
                  value.height > 2
            else { return nil }
            return (line, value)
        }
        guard !items.isEmpty else { return [] }

        var groups: [[(selection: PDFSelection, bounds: CGRect)]] = []
        for item in items {
            guard var current = groups.popLast() else {
                groups.append([item])
                continue
            }
            if let previous = current.last,
               belongsToSameTextFlow(
                   item.bounds,
                   after: previous.bounds
               ) {
                current.append(item)
                groups.append(current)
            } else {
                groups.append(current)
                groups.append([item])
            }
        }
        return groups.map { group in
            let union = group.dropFirst().reduce(group[0].bounds) {
                $0.union($1.bounds)
            }
            let ranges = group.flatMap { item in
                (0..<item.selection.numberOfTextRanges(on: page)).map {
                    item.selection.range(at: $0, on: page)
                }
            }.filter {
                $0.location != NSNotFound && $0.length > 0
            }
            let sourceRange: NSRange?
            if let minimum = ranges.map(\.location).min(),
               let maximum = ranges.map({ NSMaxRange($0) }).max() {
                sourceRange = NSRange(
                    location: minimum,
                    length: maximum - minimum
                )
            } else {
                sourceRange = nil
            }
            return (
                union.insetBy(dx: -0.75, dy: -0.5)
                    .intersection(pageBounds),
                group.count,
                group.compactMap { $0.selection.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                sourceRange
            )
        }
    }

    private func belongsToSameTextFlow(
        _ candidate: CGRect,
        after previous: CGRect
    ) -> Bool {
        let overlap = previous.intersection(candidate).width
        let minimumWidth = max(1, min(previous.width, candidate.width))
        let alignedLeft = abs(previous.minX - candidate.minX)
            <= max(18, max(previous.height, candidate.height) * 1.8)
        let sameColumn = overlap / minimumWidth >= 0.3 || alignedLeft
        let lineHeight = max(previous.height, candidate.height)
        let distance = abs(previous.midY - candidate.midY)
        let jumpedToColumnTop = candidate.midY
            > previous.midY + lineHeight * 1.4
        return sameColumn
            && !jumpedToColumnTop
            && distance <= lineHeight * 4.2
    }

    private func pdfInkColor(_ color: UIColor) -> PDFInkColor {
        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        if !resolved.getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        ) {
            var white: CGFloat = 0
            resolved.getWhite(&white, alpha: &alpha)
            red = white
            green = white
            blue = white
        }
        return PDFInkColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    private func removeAnnotation(
        in view: PDFView,
        coordinator: Coordinator
    ) {
        guard let document = view.document,
              let page = view.currentPage,
              let annotation = page.annotations.last
        else {
            onCommandMessage("No annotation to undo on this page")
            return
        }
        page.removeAnnotation(annotation)
        persist(document, coordinator: coordinator)
        onCommandMessage("Last annotation removed")
    }

    private func persist(_ document: PDFDocument, coordinator: Coordinator) {
        guard document.write(to: url) else { return }
        LocalFileSecurity.applyCompleteProtection(to: url)
        coordinator.skipsNextSelfMutationReload = true
        onMutation()
    }

    private func load(
        into view: PDFView,
        coordinator: Coordinator,
        preservingViewport: Bool
    ) {
        let viewport = preservingViewport
            ? PDFViewportState.capture(from: view)
            : nil
        resetTextSelection(in: view)
        view.document = nil
        let document = PDFDocument(url: url)
        var didUnlock = false
        if document?.isLocked == true,
           let unlockPassword,
           !unlockPassword.isEmpty {
            didUnlock = document?.unlock(withPassword: unlockPassword) == true
            onUnlock(didUnlock)
        }
        view.document = document
        view.autoScales = true
        restoreTextSelectionInteraction(in: view)
        viewport?.restore(in: view)
        coordinator.url = url
        coordinator.refreshToken = refreshToken
        coordinator.unlockPassword = unlockPassword
    }

    private func resetTextSelection(in view: PDFView) {
        view.clearSelection()
        view.currentSelection = nil
    }

    private func restoreTextSelectionInteraction(in view: PDFView) {
        view.isUserInteractionEnabled = true
        DispatchQueue.main.async {
            view.becomeFirstResponder()
        }
    }

    private struct PDFViewportState {
        let pageIndex: Int
        let pagePoint: CGPoint
        let scaleFactor: CGFloat
        let contentOffset: CGPoint?

        static func capture(from view: PDFView) -> PDFViewportState? {
            guard let document = view.document,
                  document.pageCount > 0
            else { return nil }

            let center = CGPoint(
                x: view.bounds.midX,
                y: view.bounds.midY
            )
            guard let page = view.page(for: center, nearest: true) else {
                return nil
            }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return nil }

            let scaleFactor = view.scaleFactor
            guard scaleFactor.isFinite, scaleFactor > 0 else {
                return nil
            }

            return PDFViewportState(
                pageIndex: pageIndex,
                pagePoint: view.convert(center, to: page),
                scaleFactor: scaleFactor,
                contentOffset: scrollView(in: view)?.contentOffset
            )
        }

        func restore(in view: PDFView) {
            guard let document = view.document,
                  pageIndex >= 0,
                  pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex)
            else { return }

            view.layoutIfNeeded()
            view.autoScales = false
            view.scaleFactor = clampedScaleFactor(for: view)

            if let contentOffset,
               let scrollView = Self.scrollView(in: view) {
                view.layoutIfNeeded()
                scrollView.setContentOffset(
                    Self.clamped(
                        contentOffset,
                        in: scrollView
                    ),
                    animated: false
                )
            } else {
                view.go(
                    to: PDFDestination(
                        page: page,
                        at: pagePoint
                    )
                )
            }
        }

        private func clampedScaleFactor(
            for view: PDFView
        ) -> CGFloat {
            let minimum = view.minScaleFactor > 0
                ? view.minScaleFactor
                : 0.25
            let maximum = view.maxScaleFactor > 0
                ? view.maxScaleFactor
                : max(scaleFactor, 5)
            return min(max(scaleFactor, minimum), maximum)
        }

        private static func clamped(
            _ offset: CGPoint,
            in scrollView: UIScrollView
        ) -> CGPoint {
            CGPoint(
                x: min(
                    max(offset.x, -scrollView.adjustedContentInset.left),
                    max(
                        -scrollView.adjustedContentInset.left,
                        scrollView.contentSize.width
                            - scrollView.bounds.width
                            + scrollView.adjustedContentInset.right
                    )
                ),
                y: min(
                    max(offset.y, -scrollView.adjustedContentInset.top),
                    max(
                        -scrollView.adjustedContentInset.top,
                        scrollView.contentSize.height
                            - scrollView.bounds.height
                            + scrollView.adjustedContentInset.bottom
                    )
                )
            )
        }

        private static func scrollView(in view: UIView) -> UIScrollView? {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            for subview in view.subviews {
                if let scrollView = scrollView(in: subview) {
                    return scrollView
                }
            }
            return nil
        }
    }

    private func navigate(in view: PDFView, coordinator: Coordinator) {
        coordinator.navigationToken = navigationToken
        guard let targetPageIndex,
              let document = view.document,
              targetPageIndex >= 0,
              targetPageIndex < document.pageCount,
              let page = document.page(at: targetPageIndex)
        else {
            view.accessibilityValue = nil
            return
        }
        view.go(to: page)
        view.accessibilityValue = "Page \(targetPageIndex + 1)"
    }

    private func applyEvidenceOverlay(
        _ overlay: PDFEvidenceOverlay?,
        in view: PDFView,
        coordinator: Coordinator
    ) {
        coordinator.removeEvidenceAnnotations()
        coordinator.evidenceOverlay = overlay
        guard let overlay,
              !overlay.regions.isEmpty
                || !overlay.textRegions.isEmpty
                || !overlay.characterTextRegions.isEmpty,
              let document = view.document,
              overlay.pageIndex >= 0,
              overlay.pageIndex < document.pageCount,
              let page = document.page(at: overlay.pageIndex)
        else { return }

        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            return
        }
        let baseColor: UIColor = overlay.tone == .source
            ? .systemTeal
            : .systemOrange
        for region in overlay.regions.prefix(12) {
            guard let bounds = evidenceBounds(
                region,
                pageBounds: pageBounds,
                inset: 1
            ) else { continue }
            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: .square,
                withProperties: nil
            )
            annotation.color = baseColor.withAlphaComponent(
                0.74
            )
            annotation.interiorColor = baseColor.withAlphaComponent(
                0.08 + 0.16 * min(max(region.intensity, 0), 1)
            )
            annotation.border = PDFBorder()
            annotation.border?.lineWidth = 1.2
            annotation.shouldDisplay = true
            annotation.shouldPrint = false
            annotation.isReadOnly = true
            annotation.userName = "PaperPath Evidence"
            page.addAnnotation(annotation)
            coordinator.evidenceAnnotations.append(annotation)
        }

        let textColor: UIColor = overlay.tone == .source
            ? .systemRed
            : .systemGreen
        for region in overlay.textRegions.prefix(24) {
            guard let bounds = evidenceBounds(
                region,
                pageBounds: pageBounds,
                inset: -0.5
            ) else { continue }
            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: .square,
                withProperties: nil
            )
            annotation.color = textColor.withAlphaComponent(0.9)
            annotation.interiorColor = textColor.withAlphaComponent(0.13)
            annotation.border = PDFBorder()
            annotation.border?.lineWidth = 1
            annotation.border?.style = .dashed
            annotation.shouldDisplay = true
            annotation.shouldPrint = false
            annotation.isReadOnly = true
            annotation.userName = "PaperPath Text Evidence"
            page.addAnnotation(annotation)
            coordinator.evidenceAnnotations.append(annotation)
        }

        for region in overlay.characterTextRegions.prefix(24) {
            guard let bounds = evidenceBounds(
                region,
                pageBounds: pageBounds,
                inset: -0.75
            ) else { continue }
            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: .square,
                withProperties: nil
            )
            annotation.color = textColor.withAlphaComponent(0.98)
            annotation.interiorColor = textColor.withAlphaComponent(0.2)
            annotation.border = PDFBorder()
            annotation.border?.lineWidth = 1.6
            annotation.shouldDisplay = true
            annotation.shouldPrint = false
            annotation.isReadOnly = true
            annotation.userName = "PaperPath Character Evidence"
            page.addAnnotation(annotation)
            coordinator.evidenceAnnotations.append(annotation)
        }
    }

    private func evidenceBounds(
        _ region: PDFDifferenceRegion,
        pageBounds: CGRect,
        inset: CGFloat
    ) -> CGRect? {
        let normalizedX = min(max(region.x, 0), 1)
        let normalizedY = min(max(region.y, 0), 1)
        let normalizedWidth = min(
            max(region.width, 0),
            1 - normalizedX
        )
        let normalizedHeight = min(
            max(region.height, 0),
            1 - normalizedY
        )
        let bounds = CGRect(
            x: pageBounds.minX
                + CGFloat(normalizedX) * pageBounds.width,
            y: pageBounds.maxY
                - CGFloat(
                    normalizedY + normalizedHeight
                ) * pageBounds.height,
            width: CGFloat(normalizedWidth) * pageBounds.width,
            height: CGFloat(normalizedHeight) * pageBounds.height
        ).insetBy(dx: inset, dy: inset)
        guard bounds.width > 1, bounds.height > 1 else {
            return nil
        }
        return bounds
    }

    @MainActor
    final class Coordinator: NSObject {
        var url: URL?
        var refreshToken = -1
        var navigationToken = -1
        var commandID: UUID?
        var unlockPassword: String?
        var skipsNextSelfMutationReload = false
        var evidenceOverlay: PDFEvidenceOverlay?
        var evidenceAnnotations: [PDFAnnotation] = []
        var onPageChange: (Int) -> Void
        private weak var observedView: PDFView?

        init(onPageChange: @escaping (Int) -> Void) {
            self.onPageChange = onPageChange
            super.init()
        }

        func observePageChanges(in view: PDFView) {
            observedView = view
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageDidChange),
                name: .PDFViewPageChanged,
                object: view
            )
        }

        @objc private func pageDidChange() {
            guard let view = observedView,
                  let document = view.document,
                  let page = view.currentPage
            else { return }
            let pageIndex = document.index(for: page)
            let callback = onPageChange
            DispatchQueue.main.async {
                callback(pageIndex)
            }
        }

        func removeEvidenceAnnotations() {
            for annotation in evidenceAnnotations {
                annotation.page?.removeAnnotation(annotation)
            }
            evidenceAnnotations.removeAll(keepingCapacity: true)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

struct PDFEditorPreview: Sendable {
    let imageData: Data
    let aspectRatio: Double
    let pageWidth: Double
    let pageHeight: Double

    @MainActor
    var image: UIImage? {
        UIImage(data: imageData)
    }
}

actor PDFEditorPreviewLoader {
    static let shared = PDFEditorPreviewLoader()

    private struct Key: Hashable {
        let path: String
        let pageIndex: Int
        let revision: Int
        let longEdge: Int
    }

    private var cache: [Key: PDFEditorPreview] = [:]
    private var order: [Key] = []
    private var totalBytes = 0
    private let maximumEntries = 10
    private let maximumBytes = 28 * 1_024 * 1_024

    func removeAllCachedPreviews() {
        cache.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        totalBytes = 0
    }

    func preview(
        url: URL,
        pageIndex: Int,
        revision: Int,
        longEdge: Int = 1_600
    ) async -> PDFEditorPreview? {
        let key = Key(
            path: url.standardizedFileURL.path,
            pageIndex: pageIndex,
            revision: revision,
            longEdge: longEdge
        )
        if let cached = cache[key] {
            touch(key)
            return cached
        }

        guard !Task.isCancelled,
              let document = PDFDocument(url: url),
              pageIndex >= 0,
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex)
        else { return nil }

        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(longEdge)
            / max(bounds.width, bounds.height)
        let image = page.thumbnail(
            of: CGSize(
                width: max(1, bounds.width * scale),
                height: max(1, bounds.height * scale)
            ),
            for: .cropBox
        )
        guard !Task.isCancelled,
              let imageData = image.pngData()
        else { return nil }

        let preview = PDFEditorPreview(
            imageData: imageData,
            aspectRatio: Double(bounds.width / bounds.height),
            pageWidth: Double(bounds.width),
            pageHeight: Double(bounds.height)
        )
        insert(preview, for: key)
        return preview
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func insert(
        _ preview: PDFEditorPreview,
        for key: Key
    ) {
        if let existing = cache[key] {
            totalBytes -= existing.imageData.count
        }
        cache[key] = preview
        totalBytes += preview.imageData.count
        touch(key)

        while order.count > maximumEntries
            || totalBytes > maximumBytes {
            guard let oldest = order.first else { break }
            order.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                totalBytes -= removed.imageData.count
            }
        }
    }
}

struct PDFPageThumbnailView: View {
    let url: URL
    let pageIndex: Int
    let refreshToken: Int
    var width: CGFloat = 72
    var height: CGFloat?

    private var resolvedHeight: CGFloat {
        height ?? width * 1.28
    }

    @AppStorage(AppPreferences.previewQualityKey)
    private var previewQuality =
        ThumbnailPreviewQuality.automatic.rawValue
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(PPColor.elevated)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 3,
                            style: .continuous
                        )
                    )
                    .padding(2)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: width, height: resolvedHeight)
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(PPColor.border.opacity(0.64), lineWidth: 0.55)
        }
        .task(id: "\(refreshToken)-\(pageIndex)-\(previewQuality)") {
            image = nil
            let quality = ThumbnailPreviewQuality(
                rawValue: previewQuality
            ) ?? .automatic
            let loadedImage = await PDFThumbnailLoader.thumbnail(
                url: url,
                pageIndex: pageIndex,
                revision: refreshToken,
                size: CGSize(
                    width: width * quality.renderScale,
                    height: resolvedHeight * quality.renderScale
                )
            )
            guard !Task.isCancelled else { return }
            image = loadedImage
        }
        .accessibilityLabel(
            AppLocalization.format(
                "Page %lld preview",
                pageIndex + 1
            )
        )
    }
}

private enum PDFThumbnailLoader {
    private static let cache = PDFThumbnailCache()
    private static let memoryWarningObserver: NSObjectProtocol =
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await cache.removeAll()
                await PDFEditorPreviewLoader.shared
                    .removeAllCachedPreviews()
            }
        }

    static func thumbnail(
        url: URL,
        pageIndex: Int,
        revision: Int,
        size: CGSize
    ) async -> UIImage? {
        _ = memoryWarningObserver
        let data = await cache.thumbnailData(
            url: url,
            pageIndex: pageIndex,
            revision: revision,
            size: size
        )
        guard let data else { return nil }
        return UIImage(data: data)
    }
}

private actor PDFThumbnailCache {
    private struct Entry {
        let data: Data
        var access: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var documents: [String: PDFDocument] = [:]
    private var documentOrder: [String] = []
    private var totalByteCount = 0
    private var accessCounter: UInt64 = 0

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        documents.removeAll(keepingCapacity: false)
        documentOrder.removeAll(keepingCapacity: false)
        totalByteCount = 0
    }

    func thumbnailData(
        url: URL,
        pageIndex: Int,
        revision: Int,
        size: CGSize
    ) -> Data? {
        guard !Task.isCancelled else { return nil }
        let documentKey = "\(url.path)#\(revision)"
        let key = [
            documentKey,
            String(pageIndex),
            String(Int(size.width.rounded())),
            String(Int(size.height.rounded()))
        ].joined(separator: ":")
        accessCounter &+= 1
        if var cached = entries[key] {
            cached.access = accessCounter
            entries[key] = cached
            return cached.data
        }

        let document: PDFDocument
        if let cached = documents[documentKey] {
            document = cached
        } else {
            guard let opened = PDFDocument(url: url) else { return nil }
            document = opened
            documents[documentKey] = opened
            documentOrder.removeAll { $0 == documentKey }
            documentOrder.append(documentKey)
            while documentOrder.count > maximumDocumentCount {
                let removed = documentOrder.removeFirst()
                documents[removed] = nil
                removeEntries(withDocumentKey: removed)
            }
        }
        guard !Task.isCancelled,
              let page = document.page(at: pageIndex)
        else { return nil }
        let data: Data? = autoreleasepool {
            page.thumbnail(of: size, for: .mediaBox).pngData()
        }
        guard let data, !Task.isCancelled else { return nil }
        entries[key] = Entry(data: data, access: accessCounter)
        totalByteCount += data.count
        trimIfNeeded()
        return data
    }

    private func trimIfNeeded() {
        let quality = ThumbnailPreviewQuality.selected
        while entries.count > quality.cacheEntryLimit
            || totalByteCount > quality.cacheByteLimit {
            guard let oldest = entries.min(by: {
                $0.value.access < $1.value.access
            }) else { break }
            totalByteCount -= oldest.value.data.count
            entries[oldest.key] = nil
        }
    }

    private var maximumDocumentCount: Int {
        ThumbnailPreviewQuality.selected.cacheDocumentLimit
    }

    private func removeEntries(
        withDocumentKey documentKey: String
    ) {
        let keys = entries.keys.filter {
            $0.hasPrefix(documentKey + ":")
        }
        for key in keys {
            if let entry = entries.removeValue(forKey: key) {
                totalByteCount -= entry.data.count
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onCompletion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(
        context: Context
    ) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forExporting: [url],
            asCopy: true
        )
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onCompletion: () -> Void
        private var hasCompleted = false

        init(onCompletion: @escaping () -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            complete()
        }

        func documentPickerWasCancelled(
            _ controller: UIDocumentPickerViewController
        ) {
            complete()
        }

        private func complete() {
            guard !hasCompleted else { return }
            hasCompleted = true
            onCompletion()
        }
    }
}
