import PDFKit
import SwiftUI

struct PDFTextSearchHighlight: Equatable, Sendable {
    let query: String
    let pageIndex: Int
    let contentRevisionID: UUID
}

struct PDFDocumentView: UIViewRepresentable {
    let url: URL
    let refreshToken: Int
    let targetPageIndex: Int?
    let navigationToken: Int
    let readingPreferences: PDFReadingPreferences
    let command: PDFViewCommand?
    let evidenceOverlay: PDFEvidenceOverlay?
    let searchHighlight: PDFTextSearchHighlight?
    let allowsMutation: Bool
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
        searchHighlight: PDFTextSearchHighlight? = nil,
        allowsMutation: Bool = true,
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
        self.searchHighlight = searchHighlight
        self.allowsMutation = allowsMutation
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
        applySearchHighlight(
            searchHighlight,
            in: view,
            coordinator: context.coordinator,
            revealsFirstMatch: true
        )
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPageChange = onPageChange
        coordinator.allowsMutation = allowsMutation
        // PDFKit can promote a responder while replacing its document. Do not
        // reenter SwiftUI's view graph from inside updateUIView.
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator,
                  coordinator.isObserving(view)
            else { return }
            updatePDFView(view, coordinator: coordinator)
        }
    }

    private func updatePDFView(
        _ view: PDFView,
        coordinator: Coordinator
    ) {
        applyReadingPreferences(to: view)
        let needsReload = coordinator.url != url
            || coordinator.refreshToken != refreshToken
            || coordinator.unlockPassword != unlockPassword
        let shouldPreserveViewport = needsReload
            && coordinator.url == url
            && coordinator.unlockPassword == unlockPassword
            && coordinator.navigationToken == navigationToken
        let needsNavigation =
            coordinator.navigationToken != navigationToken
        let needsSearchHighlight =
            coordinator.searchHighlight != searchHighlight
        let isSelfMutationRefresh = needsReload
            && coordinator.skipsNextSelfMutationReload
            && coordinator.url == url
            && coordinator.unlockPassword == unlockPassword
        if isSelfMutationRefresh {
            coordinator.skipsNextSelfMutationReload = false
            coordinator.refreshToken = refreshToken
        } else if needsReload {
            load(
                into: view,
                coordinator: coordinator,
                preservingViewport: shouldPreserveViewport
            )
        }
        if needsNavigation || (needsReload && !shouldPreserveViewport) {
            navigate(in: view, coordinator: coordinator)
        }
        if let command,
           coordinator.commandID != command.id {
            coordinator.commandID = command.id
            if commandWritesDocument(command.action),
               !allowsMutation || !coordinator.allowsMutation {
                deliverCommandMessage(
                    "Wait for the current document task to finish"
                )
            } else {
                execute(
                    command,
                    in: view,
                    coordinator: coordinator
                )
            }
        }
        if needsReload
            || needsNavigation
            || coordinator.evidenceOverlay != evidenceOverlay {
            applyEvidenceOverlay(
                evidenceOverlay,
                in: view,
                coordinator: coordinator
            )
        }
        if needsReload || needsNavigation || needsSearchHighlight {
            applySearchHighlight(
                searchHighlight,
                in: view,
                coordinator: coordinator,
                revealsFirstMatch:
                    needsReload || needsNavigation || needsSearchHighlight
            )
        }
    }

    static func dismantleUIView(
        _ view: PDFView,
        coordinator: Coordinator
    ) {
        coordinator.stopObservingPageChanges()
        coordinator.removeEvidenceAnnotations()
        view.highlightedSelections = nil
        view.clearSelection()
        view.document = nil
        coordinator.unlockPassword = nil
        coordinator.url = nil
        coordinator.fileRevision = nil
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
            captureRedactionMarks(
                in: view,
                coordinator: coordinator
            )
        case .captureTextForEditing:
            captureTextForEditing(
                in: view,
                coordinator: coordinator
            )
        case .removeAnnotation:
            removeAnnotation(in: view, coordinator: coordinator)
        case .zoomIn:
            adjustZoom(in: view, multiplier: 1.2)
        case .zoomOut:
            adjustZoom(in: view, multiplier: 1 / 1.2)
        case .fitToWindow:
            fitPDFToWindow(in: view)
        }
    }

    private func commandWritesDocument(
        _ action: PDFViewCommand.Action
    ) -> Bool {
        switch action {
        case .markup, .addNote, .removeAnnotation:
            return true
        case .markRedaction,
             .captureTextForEditing,
             .zoomIn,
             .zoomOut,
             .fitToWindow:
            return false
        }
    }

    private func adjustZoom(
        in view: PDFView,
        multiplier: CGFloat
    ) {
        guard view.document != nil,
              multiplier.isFinite,
              multiplier > 0
        else { return }
        view.layoutIfNeeded()
        let minimum = view.minScaleFactor > 0
            ? view.minScaleFactor
            : 0.1
        let maximum = view.maxScaleFactor > minimum
            ? view.maxScaleFactor
            : max(minimum, 8)
        let current = view.scaleFactor > 0
            ? view.scaleFactor
            : max(view.scaleFactorForSizeToFit, minimum)
        let target = min(
            max(current * multiplier, minimum),
            maximum
        )
        guard target.isFinite else { return }
        view.autoScales = false
        view.scaleFactor = target
    }

    private func fitPDFToWindow(in view: PDFView) {
        guard view.document != nil else { return }
        view.layoutIfNeeded()
        let fittedScale = view.scaleFactorForSizeToFit
        guard fittedScale.isFinite, fittedScale > 0 else {
            view.autoScales = true
            return
        }
        view.scaleFactor = fittedScale
        view.autoScales = true
    }

    private func deliverCommandMessage(_ message: String) {
        DispatchQueue.main.async {
            onCommandMessage(message)
        }
    }

    private func deliverMutation() {
        DispatchQueue.main.async {
            onMutation()
        }
    }

    private func deliverUnlock(_ didUnlock: Bool) {
        DispatchQueue.main.async {
            onUnlock(didUnlock)
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
            deliverCommandMessage("Select text in the PDF first")
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

        let selectedLines = selection.selectionsByLine()
        guard !selectedLines.isEmpty,
              selectedLines.count <= 256
        else {
            deliverCommandMessage("Select up to 256 lines at a time")
            return
        }
        var addedAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
        for line in selectedLines {
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
            annotation.userName = Self.annotationAuthor
            annotation.modificationDate = Date()
            page.addAnnotation(annotation)
            addedAnnotations.append((page, annotation))
        }
        guard !addedAnnotations.isEmpty else {
            deliverCommandMessage("The selected text has no editable bounds")
            return
        }
        let expectedCounts = annotationCounts(
            in: document,
            pages: addedAnnotations.map { $0.page }
        )
        if persist(
            document,
            expectedAnnotationCounts: expectedCounts,
            coordinator: coordinator
        ) {
            resetTextSelection(in: view)
            deliverCommandMessage("Markup saved")
        } else {
            for item in addedAnnotations {
                item.page.removeAnnotation(item.annotation)
            }
        }
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
            deliverCommandMessage("The note could not be placed")
            return
        }
        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 0,
              pageBounds.height > 0
        else {
            deliverCommandMessage("The note could not be placed")
            return
        }
        let annotationSize = CGSize(
            width: min(32, pageBounds.width),
            height: min(32, pageBounds.height)
        )
        let viewportCenter = view.convert(
            CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: page
        )
        let visibleOrigin = CGPoint(
            x: min(
                max(pageBounds.minX, viewportCenter.x - annotationSize.width / 2),
                pageBounds.maxX - annotationSize.width
            ),
            y: min(
                max(pageBounds.minY, viewportCenter.y - annotationSize.height / 2),
                pageBounds.maxY - annotationSize.height
            )
        )
        let annotation = PDFAnnotation(
            bounds: CGRect(origin: visibleOrigin, size: annotationSize),
            forType: .text,
            withProperties: nil
        )
        annotation.contents = text
        annotation.color = .systemOrange
        annotation.iconType = .comment
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        annotation.userName = Self.annotationAuthor
        annotation.modificationDate = Date()
        page.addAnnotation(annotation)
        let expectedCounts = annotationCounts(
            in: document,
            pages: [page]
        )
        if persist(
            document,
            expectedAnnotationCounts: expectedCounts,
            coordinator: coordinator
        ) {
            deliverCommandMessage("Note added to the current page")
        } else {
            page.removeAnnotation(annotation)
        }
    }

    private func captureRedactionMarks(
        in view: PDFView,
        coordinator: Coordinator
    ) {
        guard let document = view.document,
              let selection = coordinator.selectionForCommand(in: view)
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
        let cleanedMarks = PDFRedactionMarkSanitizer.clean(marks)
        view.clearSelection()
        coordinator.resetSelectionSnapshot()
        DispatchQueue.main.async {
            onRedactionMarks(cleanedMarks)
        }
    }

    private func captureTextForEditing(
        in view: PDFView,
        coordinator: Coordinator
    ) {
        guard let document = view.document,
              let selection = coordinator.selectionForCommand(in: view),
              (1...4).contains(selection.pages.count),
              let firstPage = selection.pages.min(by: {
                  document.index(for: $0) < document.index(for: $1)
              }),
              let selectedText = selection.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedText.isEmpty
        else {
            deliverCommandMessage("Select text across no more than four pages")
            return
        }
        let lines = selection.selectionsByLine()
        guard !lines.isEmpty, lines.count <= 96 else {
            deliverCommandMessage("Select up to 96 lines")
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
            deliverCommandMessage("The selected text has no editable bounds")
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
                deliverCommandMessage("One selected page has invalid bounds")
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
            deliverCommandMessage("Select no more than sixteen text boxes")
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
        coordinator.resetSelectionSnapshot()
        DispatchQueue.main.async {
            onTextSelection(snapshot)
        }
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
              let annotation = page.annotations.last(where: {
                  $0.userName == Self.annotationAuthor
              })
        else {
            deliverCommandMessage(
                "No PaperPath annotation to undo on this page"
            )
            return
        }
        page.removeAnnotation(annotation)
        let expectedCounts = annotationCounts(
            in: document,
            pages: [page]
        )
        if persist(
            document,
            expectedAnnotationCounts: expectedCounts,
            coordinator: coordinator
        ) {
            deliverCommandMessage("Last annotation removed")
        } else {
            page.addAnnotation(annotation)
        }
    }

    private func persist(
        _ document: PDFDocument,
        expectedAnnotationCounts: [Int: Int],
        coordinator: Coordinator
    ) -> Bool {
        guard let expectedRevision = coordinator.fileRevision,
              fileRevision(at: url) == expectedRevision
        else {
            deliverCommandMessage(
                "The PDF changed before this annotation was saved. Reopen it and try again."
            )
            return false
        }
        guard hasCapacityForAnnotationWrite(
            sourceBytes: expectedRevision.fileSize
        ) else {
            deliverCommandMessage(
                PaperPathError.insufficientStorage.errorDescription
                    ?? "There isn’t enough free space to save this annotation."
            )
            return false
        }

        let fileManager = FileManager.default
        let stagingURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".annotation-\(UUID().uuidString).pdf",
                isDirectory: false
            )
        let rollbackName =
            ".annotation-rollback-\(UUID().uuidString).pdf"
        let rollbackURL = url.deletingLastPathComponent()
            .appendingPathComponent(rollbackName)
        let suspendedEvidence = coordinator.detachEvidenceAnnotations()
        defer {
            coordinator.restoreEvidenceAnnotations(suspendedEvidence)
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: rollbackURL)
        }

        guard document.write(to: stagingURL) else {
            deliverCommandMessage(
                "The annotation could not be saved. Your existing PDF was not changed."
            )
            return false
        }
        do {
            try LocalFileSecurity.requireCompleteProtection(
                to: stagingURL,
                fileManager: fileManager
            )
            guard let reopened = PDFDocument(url: stagingURL) else {
                deliverCommandMessage(
                    "The saved annotation could not be verified. Your existing PDF was not changed."
                )
                return false
            }
            if reopened.isLocked {
                guard let unlockPassword,
                      !unlockPassword.isEmpty,
                      reopened.unlock(withPassword: unlockPassword)
                else {
                    deliverCommandMessage(
                        "The saved annotation could not be verified. Your existing PDF was not changed."
                    )
                    return false
                }
            }
            guard reopened.pageCount == document.pageCount else {
                deliverCommandMessage(
                    "The saved annotation could not be verified. Your existing PDF was not changed."
                )
                return false
            }
            for (pageIndex, expectedCount) in expectedAnnotationCounts {
                guard pageIndex >= 0,
                      pageIndex < reopened.pageCount,
                      let page = reopened.page(at: pageIndex),
                      page.annotations.filter({
                          $0.userName == Self.annotationAuthor
                      }).count == expectedCount
                else {
                    deliverCommandMessage(
                        "The saved annotation could not be verified. Your existing PDF was not changed."
                    )
                    return false
                }
            }
            guard fileRevision(at: url) == expectedRevision else {
                deliverCommandMessage(
                    "The PDF changed before this annotation was saved. Reopen it and try again."
                )
                return false
            }
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: stagingURL,
                backupItemName: rollbackName,
                options: [.withoutDeletingBackupItem]
            )
            if fileManager.fileExists(atPath: rollbackURL.path) {
                try LocalFileSecurity.requireCompleteProtection(
                    to: rollbackURL,
                    fileManager: fileManager
                )
            }
            try LocalFileSecurity.requireCompleteProtection(
                to: url,
                fileManager: fileManager
            )
        } catch {
            let restored = restoreAnnotationRollback(
                from: rollbackURL,
                expectedRevision: expectedRevision,
                fileManager: fileManager
            )
            deliverCommandMessage(
                restored
                    ? "The annotation could not be saved. Your existing PDF was not changed."
                    : "The annotation could not be saved. Reopen the PDF and verify its contents."
            )
            return false
        }

        coordinator.fileRevision = fileRevision(at: url)
        coordinator.skipsNextSelfMutationReload = true
        deliverMutation()
        return true
    }

    private func restoreAnnotationRollback(
        from rollbackURL: URL,
        expectedRevision: PDFFileRevision,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: rollbackURL.path) else {
            return fileRevision(at: url) == expectedRevision
        }
        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: rollbackURL
                )
            } else {
                try fileManager.moveItem(at: rollbackURL, to: url)
            }
            try LocalFileSecurity.requireCompleteProtection(
                to: url,
                fileManager: fileManager
            )
            return fileRevision(at: url) == expectedRevision
        } catch {
            return false
        }
    }

    private func annotationCounts(
        in document: PDFDocument,
        pages: [PDFPage]
    ) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for page in pages {
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound,
                  counts[pageIndex] == nil
            else { continue }
            counts[pageIndex] = page.annotations.filter {
                $0.userName == Self.annotationAuthor
            }.count
        }
        return counts
    }

    private func hasCapacityForAnnotationWrite(
        sourceBytes: Int64
    ) -> Bool {
        let directory = url.deletingLastPathComponent()
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available =
                values?.volumeAvailableCapacityForImportantUsage
        else { return true }
        let reserve = Int64(16 * 1_024 * 1_024)
        let (required, overflow) = max(0, sourceBytes)
            .addingReportingOverflow(reserve)
        return !overflow && available >= required
    }

    private func fileRevision(at url: URL) -> PDFFileRevision? {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        return PDFFileRevision(
            fileSize: size,
            modificationDate: attributes[.modificationDate] as? Date,
            fileNumber: (
                attributes[.systemFileNumber] as? NSNumber
            )?.uint64Value
        )
    }

    private func load(
        into view: PDFView,
        coordinator: Coordinator,
        preservingViewport: Bool
    ) {
#if DEBUG
        // #region debug-point D:experience-presentations
        if let endpoint = ProcessInfo.processInfo.environment["DEBUG_SERVER_URL"], let url = URL(string: endpoint) { var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "experience-presentations", "runId": ProcessInfo.processInfo.environment["DEBUG_RUN_ID"] ?? "pre-fix", "hypothesisId": "D", "location": "PDFDocumentView.load.begin", "msg": "[DEBUG] PDF reload entered", "data": ["preservesViewport": preservingViewport]]); URLSession.shared.dataTask(with: request).resume() }
        // #endregion
#endif
        let viewport = preservingViewport
            ? PDFViewportState.capture(from: view)
            : nil
        coordinator.resetSelectionSnapshot()
        resetTextSelection(in: view)
        view.document = nil
        let document = PDFDocument(url: url)
        if let document,
           let unlockPassword,
           !unlockPassword.isEmpty {
            let didUnlock = !document.isLocked
                || document.unlock(withPassword: unlockPassword)
            deliverUnlock(didUnlock)
        }
        view.document = document
        view.autoScales = true
        restoreTextSelectionInteraction(in: view)
        viewport?.restore(in: view)
        coordinator.url = url
        coordinator.refreshToken = refreshToken
        coordinator.unlockPassword = unlockPassword
        coordinator.fileRevision = fileRevision(at: url)
#if DEBUG
        // #region debug-point D:experience-presentations
        if let endpoint = ProcessInfo.processInfo.environment["DEBUG_SERVER_URL"], let url = URL(string: endpoint) { var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "experience-presentations", "runId": ProcessInfo.processInfo.environment["DEBUG_RUN_ID"] ?? "pre-fix", "hypothesisId": "D", "location": "PDFDocumentView.load.end", "msg": "[DEBUG] PDF reload returned"]); URLSession.shared.dataTask(with: request).resume() }
        // #endregion
#endif
    }

    private func resetTextSelection(in view: PDFView) {
        view.highlightedSelections = nil
        view.clearSelection()
        view.currentSelection = nil
    }

    private func restoreTextSelectionInteraction(in view: PDFView) {
        view.isUserInteractionEnabled = true
    }

    @MainActor
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
        view.accessibilityValue = AppLocalization.format(
            "Page %lld",
            targetPageIndex + 1
        )
    }

    private func applySearchHighlight(
        _ highlight: PDFTextSearchHighlight?,
        in view: PDFView,
        coordinator: Coordinator,
        revealsFirstMatch: Bool
    ) {
        coordinator.searchHighlight = highlight
        view.highlightedSelections = nil
        guard let highlight,
              let document = view.document,
              highlight.pageIndex >= 0,
              highlight.pageIndex < document.pageCount,
              let page = document.page(at: highlight.pageIndex),
              let pageText = page.string,
              !pageText.isEmpty
        else { return }

        let terms = DocumentSearchNormalization.terms(
            in: highlight.query
        )
        guard !terms.isEmpty else { return }

        let selectionLimit = 32
        let perTermLimit = max(1, selectionLimit / terms.count)
        var locatedSelections: [
            (location: Int, selection: PDFSelection)
        ] = []
        locatedSelections.reserveCapacity(selectionLimit)

        for term in terms {
            var termSelectionCount = 0
            var searchStart = pageText.startIndex
            while searchStart < pageText.endIndex,
                  locatedSelections.count < selectionLimit,
                  termSelectionCount < perTermLimit,
                  let range = pageText.range(
                      of: term,
                      options: [
                          .caseInsensitive,
                          .diacriticInsensitive,
                          .widthInsensitive
                      ],
                      range: searchStart..<pageText.endIndex,
                      locale: nil
                  ) {
                let sourceRange = NSRange(range, in: pageText)
                if let selection = page.selection(for: sourceRange) {
                    selection.color = UIColor.systemYellow
                        .withAlphaComponent(0.42)
                    locatedSelections.append(
                        (sourceRange.location, selection)
                    )
                    termSelectionCount += 1
                }
                searchStart = range.upperBound
            }
            if locatedSelections.count == selectionLimit {
                break
            }
        }

        locatedSelections.sort { $0.location < $1.location }
        let selections = locatedSelections.map(\.selection)
        guard !selections.isEmpty else { return }
        view.highlightedSelections = selections
        view.accessibilityValue = AppLocalization.format(
            "Page %lld, search terms highlighted",
            highlight.pageIndex + 1
        )
        if revealsFirstMatch, let first = selections.first {
            view.go(to: first)
        }
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
                || !overlay.characterTextRegions.isEmpty
                || !overlay.vectorRegions.isEmpty,
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

        for region in overlay.vectorRegions.prefix(24) {
            guard let bounds = evidenceBounds(
                region,
                pageBounds: pageBounds,
                inset: -1
            ) else { continue }
            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: .square,
                withProperties: nil
            )
            annotation.color = baseColor.withAlphaComponent(0.96)
            annotation.interiorColor = .clear
            annotation.border = PDFBorder()
            annotation.border?.lineWidth = 2
            annotation.shouldDisplay = true
            annotation.shouldPrint = false
            annotation.isReadOnly = true
            annotation.userName = "PaperPath Vector Evidence"
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

    private static let annotationAuthor = "PaperPath"

    fileprivate struct PDFFileRevision: Equatable {
        let fileSize: Int64
        let modificationDate: Date?
        let fileNumber: UInt64?
    }

    @MainActor
    final class Coordinator: NSObject {
        var url: URL?
        var refreshToken = -1
        var navigationToken = -1
        var commandID: UUID?
        var allowsMutation = true
        var unlockPassword: String?
        fileprivate var fileRevision: PDFFileRevision?
        var skipsNextSelfMutationReload = false
        var evidenceOverlay: PDFEvidenceOverlay?
        var searchHighlight: PDFTextSearchHighlight?
        var evidenceAnnotations: [PDFAnnotation] = []
        var onPageChange: (Int) -> Void
        private weak var observedView: PDFView?
        private var pageChangeGeneration = 0
        private var lastDeliveredPageIndex: Int?
        private var recentSelection: PDFSelection?
        private var selectionClearedAt: TimeInterval?

        init(onPageChange: @escaping (Int) -> Void) {
            self.onPageChange = onPageChange
            super.init()
        }

        func isObserving(_ view: PDFView) -> Bool {
            observedView === view
        }

        func observePageChanges(in view: PDFView) {
            stopObservingPageChanges()
            observedView = view
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageDidChange),
                name: .PDFViewPageChanged,
                object: view
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionDidChange),
                name: .PDFViewSelectionChanged,
                object: view
            )
        }

        @objc private func pageDidChange() {
            pageChangeGeneration &+= 1
            let generation = pageChangeGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.pageChangeGeneration == generation,
                      let view = self.observedView,
                      let document = view.document,
                      let page = view.currentPage
                else { return }
                let pageIndex = document.index(for: page)
                guard pageIndex != NSNotFound,
                      pageIndex >= 0,
                      pageIndex < document.pageCount,
                      pageIndex != self.lastDeliveredPageIndex
                else { return }
                self.lastDeliveredPageIndex = pageIndex
                self.onPageChange(pageIndex)
            }
        }

        func stopObservingPageChanges() {
            pageChangeGeneration &+= 1
            if let observedView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: .PDFViewPageChanged,
                    object: observedView
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: .PDFViewSelectionChanged,
                    object: observedView
                )
            }
            observedView = nil
            lastDeliveredPageIndex = nil
            resetSelectionSnapshot()
        }

        @objc private func selectionDidChange() {
            guard let view = observedView else {
                resetSelectionSnapshot()
                return
            }
            guard let selection = view.currentSelection,
                  selection.string?.isEmpty == false
            else {
                if recentSelection != nil {
                    selectionClearedAt =
                        ProcessInfo.processInfo.systemUptime
                }
                return
            }
            recentSelection = selection.copy() as? PDFSelection
            selectionClearedAt = nil
        }

        func selectionForCommand(
            in view: PDFView
        ) -> PDFSelection? {
            if let selection = view.currentSelection,
               selection.string?.isEmpty == false {
                return selection
            }
            guard let recentSelection,
                  let selectionClearedAt,
                  ProcessInfo.processInfo.systemUptime
                    - selectionClearedAt <= 1,
                  let document = view.document,
                  recentSelection.pages.allSatisfy({
                      document.index(for: $0) != NSNotFound
                  })
            else {
                resetSelectionSnapshot()
                return nil
            }
            return recentSelection
        }

        func resetSelectionSnapshot() {
            recentSelection = nil
            selectionClearedAt = nil
        }

        func removeEvidenceAnnotations() {
            _ = detachEvidenceAnnotations()
        }

        func detachEvidenceAnnotations() -> [
            (page: PDFPage, annotation: PDFAnnotation)
        ] {
            let detached = evidenceAnnotations.compactMap {
                annotation -> (
                    page: PDFPage,
                    annotation: PDFAnnotation
                )? in
                guard let page = annotation.page else { return nil }
                page.removeAnnotation(annotation)
                return (page, annotation)
            }
            evidenceAnnotations.removeAll(keepingCapacity: true)
            return detached
        }

        func restoreEvidenceAnnotations(
            _ annotations: [
                (page: PDFPage, annotation: PDFAnnotation)
            ]
        ) {
            for item in annotations {
                item.page.addAnnotation(item.annotation)
            }
            evidenceAnnotations = annotations.map(\.annotation)
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

private struct PDFPreviewSource: Hashable {
    let path: String
    let revision: Int
    let byteCount: UInt64
    let modifiedAt: Date
    let fileNumber: UInt64

    init?(url: URL, revision: Int) {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: url.path
              ),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.uint64Value > 0,
              let modifiedAt = attributes[.modificationDate] as? Date,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber
        else { return nil }
        path = url.standardizedFileURL.path
        self.revision = revision
        byteCount = size.uint64Value
        self.modifiedAt = modifiedAt
        self.fileNumber = fileNumber.uint64Value
    }
}

actor PDFEditorPreviewLoader {
    static let shared = PDFEditorPreviewLoader()
    private static let maximumPreviewPixels = 6_000_000
    private static let maximumPreviewBytes = 24 * 1_024 * 1_024

    private struct Key: Hashable {
        let source: PDFPreviewSource
        let pageIndex: Int
        let longEdge: Int
    }

    private var cache: [Key: PDFEditorPreview] = [:]
    private var order: [Key] = []
    private var totalBytes = 0
    private var cacheGeneration = UUID()

    private var maximumEntries: Int {
        max(
            3,
            min(10, ThumbnailPreviewQuality.selected.cacheEntryLimit / 8)
        )
    }

    private var maximumBytes: Int {
        max(
            8 * 1_024 * 1_024,
            min(
                28 * 1_024 * 1_024,
                ThumbnailPreviewQuality.selected.cacheByteLimit * 2
            )
        )
    }

    func removeAllCachedPreviews() {
        cacheGeneration = UUID()
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
        guard await PDFThumbnailLoader.prepareForRendering(),
              !Task.isCancelled,
              let source = PDFPreviewSource(url: url, revision: revision)
        else { return nil }
        let generation = cacheGeneration
        trimIfNeeded()
        let resolvedLongEdge = min(max(longEdge, 256), 2_400)
        let key = Key(
            source: source,
            pageIndex: pageIndex,
            longEdge: resolvedLongEdge
        )
        for staleKey in order.filter({
            $0.source.path == source.path && $0.source != source
        }) {
            if let removed = cache.removeValue(forKey: staleKey) {
                totalBytes -= removed.imageData.count
            }
            order.removeAll { $0 == staleKey }
        }
        if let cached = cache[key] {
            touch(key)
            return cached
        }

        guard !Task.isCancelled,
              let document = PDFDocument(url: url),
              !document.isLocked,
              pageIndex >= 0,
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex)
        else { return nil }

        let bounds = page.bounds(for: .cropBox)
        guard bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0
        else { return nil }
        let scale = CGFloat(resolvedLongEdge)
            / max(bounds.width, bounds.height)
        let rendered = autoreleasepool {
            let image = page.thumbnail(
                of: CGSize(
                    width: max(1, bounds.width * scale),
                    height: max(1, bounds.height * scale)
                ),
                for: .cropBox
            )
            guard let cgImage = image.cgImage,
                  cgImage.width > 0,
                  cgImage.height > 0
            else { return nil as Data? }
            let pixels = cgImage.width.multipliedReportingOverflow(
                by: cgImage.height
            )
            guard !pixels.overflow,
                  pixels.partialValue <= Self.maximumPreviewPixels,
                  let data = image.pngData(),
                  !data.isEmpty,
                  data.count <= Self.maximumPreviewBytes
            else { return nil }
            return data
        }
        guard let imageData = rendered,
              await PDFThumbnailLoader.prepareForRendering(),
              !Task.isCancelled,
              generation == cacheGeneration,
              PDFPreviewSource(url: url, revision: revision) == source
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
        trimIfNeeded()
    }

    private func trimIfNeeded() {
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

enum PDFPagePreviewWindow {
    static func indices(pageCount: Int, selectedPage: Int) -> Range<Int> {
        let count = max(0, pageCount)
        let visibleCount = min(9, count)
        let selected = min(max(0, selectedPage), max(0, count - 1))
        let start = min(max(0, selected - visibleCount / 2), count - visibleCount)
        return start..<(start + visibleCount)
    }
}

struct PDFPageFilmstrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let url: URL
    let pageCount: Int
    let refreshToken: Int
    @Binding var selectedPage: Int
    var showsThumbnails = true
    var onChoosePage: (() -> Void)?

    private var currentPage: Int {
        min(max(0, selectedPage), max(0, pageCount - 1))
    }

    var body: some View {
        VStack(spacing: PPSpacing.xSmall) {
            HStack(spacing: PPSpacing.small) {
                pageButton("Previous page", symbol: "chevron.left", offset: -1)
                    .disabled(currentPage == 0)
                Button {
                    onChoosePage?()
                } label: {
                    Text(AppLocalization.format(
                        "Page %lld of %lld", currentPage + 1, max(1, pageCount)
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: PPDeskLayout.touchTarget)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("l", modifiers: .command)
                .disabled(onChoosePage == nil)
                .accessibilityLabel("Go to page".localizedUI)
                .accessibilityValue(AppLocalization.format(
                    "Page %lld of %lld", currentPage + 1, max(1, pageCount)
                ))
                pageButton("Next page", symbol: "chevron.right", offset: 1)
                    .disabled(currentPage >= pageCount - 1)
            }

            if pageCount > 1, showsThumbnails {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: PPSpacing.small) {
                            ForEach(
                                PDFPagePreviewWindow.indices(
                                    pageCount: pageCount, selectedPage: currentPage
                                ), id: \.self
                            ) { page in
                                Button {
                                    selectedPage = page
                                } label: {
                                    VStack(spacing: PPSpacing.xSmall) {
                                        PDFPageThumbnailView(
                                            url: url, pageIndex: page,
                                            refreshToken: refreshToken, width: 44
                                        )
                                        .accessibilityHidden(true)
                                        Text("\(page + 1)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(
                                                page == currentPage
                                                    ? PPColor.accent : PPColor.textSecondary
                                            )
                                    }
                                    .padding(PPSpacing.xSmall)
                                    .frame(width: 56)
                                    .background(
                                        page == currentPage
                                            ? PPColor.surface : Color.clear,
                                        in: RoundedRectangle(cornerRadius: PPRadius.control)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: PPRadius.control)
                                            .strokeBorder(
                                                page == currentPage
                                                    ? PPColor.accent : .clear,
                                                lineWidth: 2
                                            )
                                    }
                                }
                                .buttonStyle(.plain)
                                .hoverEffect(.highlight)
                                .id(page)
                                .accessibilityLabel(AppLocalization.format(
                                    "Page %lld preview", page + 1
                                ))
                                .accessibilityAddTraits(page == currentPage ? .isSelected : [])
                                .accessibilityIdentifier("pageFilmstrip-\(page)")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: currentPage, initial: true) { _, page in
                        withAnimation(reduceMotion ? nil : PPMotion.selection) {
                            proxy.scrollTo(page, anchor: .center)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pdfPageFilmstrip")
    }

    private func pageButton(
        _ title: String, symbol: String, offset: Int
    ) -> some View {
        Button {
            selectedPage = min(max(0, currentPage + offset), max(0, pageCount - 1))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: PPDeskLayout.touchTarget, height: PPDeskLayout.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(offset < 0 ? .leftArrow : .rightArrow, modifiers: .option)
        .help(title.localizedUI)
        .accessibilityLabel(title.localizedUI)
    }
}

struct PDFPageThumbnailView: View {
    @Environment(\.scenePhase) private var scenePhase

    let url: URL
    let pageIndex: Int
    let refreshToken: Int
    var width: CGFloat = 72
    var height: CGFloat?

    private var resolvedHeight: CGFloat {
        height ?? width * 1.28
    }

    private var renderSize: CGSize {
        let quality = ThumbnailPreviewQuality(
            rawValue: previewQuality
        ) ?? .automatic
        func bucket(_ value: CGFloat) -> CGFloat {
            guard value.isFinite, value > 0 else { return 32 }
            return min(1_200, max(32, (value / 32).rounded(.up) * 32))
        }
        return CGSize(
            width: bucket(width * quality.renderScale),
            height: bucket(resolvedHeight * quality.renderScale)
        )
    }

    private var imageIdentity: String {
        "\(url.standardizedFileURL.path)#\(refreshToken)#\(pageIndex)"
    }

    private var thumbnailTaskID: String {
        [
            url.standardizedFileURL.path,
            String(refreshToken),
            String(pageIndex),
            previewQuality,
            scenePhase == .background ? "paused" : "visible",
            String(protectedDataAvailable),
            String(Int(renderSize.width)),
            String(Int(renderSize.height))
        ].joined(separator: "#")
    }

    @AppStorage(AppPreferences.previewQualityKey)
    private var previewQuality =
        ThumbnailPreviewQuality.automatic.rawValue
    @State private var image: UIImage?
    @State private var loadedImageIdentity: String?
    @State private var didFinishLoading = false
    @State private var protectedDataAvailable =
        UIApplication.shared.isProtectedDataAvailable

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
            } else if didFinishLoading {
                Image(systemName: "doc")
                    .font(.title3)
                    .foregroundStyle(PPColor.textSecondary)
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
        .task(id: thumbnailTaskID) {
            let requestedIdentity = imageIdentity
            if loadedImageIdentity != requestedIdentity {
                image = nil
            }
            didFinishLoading = false
            guard scenePhase != .background,
                  protectedDataAvailable,
                  UIApplication.shared.isProtectedDataAvailable
            else {
                image = nil
                loadedImageIdentity = nil
                return
            }
            let loadedImage = await PDFThumbnailLoader.thumbnail(
                url: url,
                pageIndex: pageIndex,
                revision: refreshToken,
                size: renderSize
            )
            guard !Task.isCancelled,
                  imageIdentity == requestedIdentity,
                  scenePhase != .background,
                  protectedDataAvailable,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            image = loadedImage
            loadedImageIdentity = requestedIdentity
            didFinishLoading = true
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            protectedDataAvailable = false
            image = nil
            loadedImageIdentity = nil
            didFinishLoading = false
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            protectedDataAvailable = true
        }
        .onDisappear {
            image = nil
            loadedImageIdentity = nil
        }
        .accessibilityLabel(
            AppLocalization.format(
                "Page %lld preview",
                pageIndex + 1
            )
        )
        .accessibilityValue(
            (
                image != nil
                    ? "Ready"
                    : didFinishLoading
                        ? "Preview unavailable"
                        : "Loading"
            ).localizedUI
        )
    }
}

private enum PDFThumbnailLoader {
    private static let cache = PDFThumbnailCache()
    @MainActor
    private static let cachePressureObservers: [NSObjectProtocol] = [
        UIApplication.didReceiveMemoryWarningNotification,
        UIApplication.didEnterBackgroundNotification,
        UIApplication.protectedDataWillBecomeUnavailableNotification
    ].map { name in
        NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await cache.removeAll()
                await PDFEditorPreviewLoader.shared
                    .removeAllCachedPreviews()
            }
        }
    }

    @MainActor
    static func prepareForRendering() -> Bool {
        _ = cachePressureObservers
        return UIApplication.shared.isProtectedDataAvailable
            && UIApplication.shared.applicationState != .background
    }

    @MainActor
    static func thumbnail(
        url: URL,
        pageIndex: Int,
        revision: Int,
        size: CGSize
    ) async -> UIImage? {
        guard !Task.isCancelled,
              prepareForRendering()
        else { return nil }
        let data = await cache.thumbnailData(
            url: url,
            pageIndex: pageIndex,
            revision: revision,
            size: size
        )
        guard let data,
              !Task.isCancelled,
              prepareForRendering()
        else { return nil }
        return UIImage(data: data)
    }
}

private actor PDFThumbnailCache {
    private struct Key: Hashable {
        let source: PDFPreviewSource
        let pageIndex: Int
        let width: Int
        let height: Int
    }

    private struct Entry {
        let data: Data
        var access: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var documents: [PDFPreviewSource: PDFDocument] = [:]
    private var documentOrder: [PDFPreviewSource] = []
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
        guard !Task.isCancelled,
              pageIndex >= 0,
              let source = PDFPreviewSource(url: url, revision: revision),
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else { return nil }
        let resolvedSize = CGSize(
            width: min(max(size.width.rounded(.up), 1), 1_200),
            height: min(max(size.height.rounded(.up), 1), 1_200)
        )
        let documentKey = source
        let key = Key(
            source: source,
            pageIndex: pageIndex,
            width: Int(resolvedSize.width),
            height: Int(resolvedSize.height)
        )
        let staleSources = Set(entries.keys.map(\.source))
            .union(documents.keys)
            .filter { $0.path == source.path && $0 != source }
        for stale in staleSources {
            documents[stale] = nil
            documentOrder.removeAll { $0 == stale }
            removeEntries(withDocumentKey: stale)
        }
        accessCounter &+= 1
        trimDocumentsIfNeeded()
        trimIfNeeded()
        if var cached = entries[key] {
            cached.access = accessCounter
            entries[key] = cached
            return cached.data
        }

        let document: PDFDocument
        if let cached = documents[documentKey] {
            document = cached
            touchDocument(documentKey)
        } else {
            guard let opened = PDFDocument(url: url),
                  !opened.isLocked
            else { return nil }
            document = opened
            documents[documentKey] = opened
            touchDocument(documentKey)
            trimDocumentsIfNeeded()
        }
        guard !Task.isCancelled,
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex)
        else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0
        else { return nil }
        let rendered = autoreleasepool {
            let image = page.thumbnail(
                of: resolvedSize,
                for: .cropBox
            )
            guard let cgImage = image.cgImage,
                  cgImage.width > 0,
                  cgImage.height > 0
            else { return nil as Data? }
            let pixels = cgImage.width.multipliedReportingOverflow(
                by: cgImage.height
            )
            guard !pixels.overflow,
                  pixels.partialValue <= 1_440_000,
                  let data = image.pngData(),
                  !data.isEmpty,
                  data.count <= 5 * 1_024 * 1_024
            else { return nil }
            return data
        }
        guard let data = rendered, !Task.isCancelled,
              PDFPreviewSource(url: url, revision: revision) == source
        else { return nil }
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

    private func trimDocumentsIfNeeded() {
        while documentOrder.count > maximumDocumentCount {
            let removed = documentOrder.removeFirst()
            documents[removed] = nil
        }
    }

    private func touchDocument(_ documentKey: PDFPreviewSource) {
        documentOrder.removeAll { $0 == documentKey }
        documentOrder.append(documentKey)
    }

    private func removeEntries(
        withDocumentKey documentKey: PDFPreviewSource
    ) {
        let keys = entries.keys.filter {
            $0.source == documentKey
        }
        for key in keys {
            if let entry = entries.removeValue(forKey: key) {
                totalByteCount -= entry.data.count
            }
        }
    }
}

private final class ManagedShareLease {
    private var leaseID: UUID?
    private var protectedDataObserver: NSObjectProtocol?

    func begin(for urls: [URL], removesItemsOnCompletion: Bool = true) {
        finish()
        guard let leaseID =
            PaperPathTemporaryArtifact.beginShareLease(
                for: urls,
                removesItemsOnCompletion: removesItemsOnCompletion
            )
        else { return }
        self.leaseID = leaseID
        protectedDataObserver = NotificationCenter.default
            .addObserver(
                forName: UIApplication
                    .protectedDataWillBecomeUnavailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.finish(forcesCleanup: true)
            }
    }

    func finish(forcesCleanup: Bool = false) {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(
                protectedDataObserver
            )
            self.protectedDataObserver = nil
        }
        guard let leaseID else { return }
        self.leaseID = nil
        PaperPathTemporaryArtifact.endShareLease(
            leaseID,
            forcesCleanup: forcesCleanup
        )
    }

    deinit {
        finish()
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var removesTemporaryItemsOnCompletion = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        context.coordinator.beginShareLease(
            for: items,
            removesItemsOnCompletion: removesTemporaryItemsOnCompletion
        )
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = {
            _,
            _,
            _,
            _ in
            coordinator.finishShareLease()
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}

    final class Coordinator {
        private let shareLease = ManagedShareLease()

        func beginShareLease(for items: [Any], removesItemsOnCompletion: Bool) {
            shareLease.begin(
                for: items.compactMap { $0 as? URL },
                removesItemsOnCompletion: removesItemsOnCompletion
            )
        }

        func finishShareLease(
            forcesCleanup: Bool = false
        ) {
            shareLease.finish(forcesCleanup: forcesCleanup)
        }
    }
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
        context.coordinator.beginShareLease(for: url)
        let picker = UIDocumentPickerViewController(
            forExporting: [url],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.view.accessibilityIdentifier = "fileExportPicker"
#if DEBUG
        // #region debug-point G:files-picker-created
        reportFrequentUIFreezeDebugEvent(
            hypothesisID: "G",
            location: "FileExportPicker.makeUIViewController",
            message: "Files picker created",
            data: [
                "fileExists": String(
                    FileManager.default.fileExists(atPath: url.path)
                )
            ]
        )
        // #endregion
#endif
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onCompletion: () -> Void
        private let shareLease = ManagedShareLease()
        private var hasCompleted = false

        init(onCompletion: @escaping () -> Void) {
            self.onCompletion = onCompletion
        }

        func beginShareLease(for url: URL) {
            shareLease.begin(for: [url])
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
            shareLease.finish()
            onCompletion()
        }
    }
}
