import CryptoKit
import Foundation
import PDFKit
import UIKit

private struct PDFInkRenderStyle: Hashable {
    let color: PDFInkColor?
    let halfPointWidth: Int
}

struct PDFMutationService: Sendable {
    private static let maximumPageCount = 100_000
    private static let maximumAnnotationsPerPage = 4_096
    private static let maximumAnnotationsScanned = 100_000

    enum MoveDirection: Sendable {
        case earlier
        case later
    }

    enum RotationDirection: Sendable, Equatable {
        case clockwise
        case counterclockwise

        var degrees: Int {
            switch self {
            case .clockwise: return 90
            case .counterclockwise: return -90
            }
        }
    }

    func annotations(
        in url: URL,
        limit: Int? = nil
    ) throws -> [PDFAnnotationSnapshot] {
        guard let document = PDFDocument(url: url),
              !document.isLocked
        else {
            throw PaperPathError.unreadablePDF
        }
        try Self.requireSupportedPageCount(document.pageCount)
        let resultLimit = limit.map { max(1, min($0, 10_001)) }
        var results: [PDFAnnotationSnapshot] = []
        if let resultLimit {
            results.reserveCapacity(min(resultLimit, 512))
        }
        var scannedAnnotationCount = 0
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            let annotations = page.annotations
            guard annotations.count <= Self.maximumAnnotationsPerPage
            else {
                throw PaperPathError.insufficientSelection(
                    "A PDF page contains too many annotations to inspect safely."
                )
            }
            let nextScannedCount = scannedAnnotationCount
                .addingReportingOverflow(annotations.count)
            guard !nextScannedCount.overflow,
                  nextScannedCount.partialValue
                    <= Self.maximumAnnotationsScanned
            else {
                throw PaperPathError.insufficientSelection(
                    "This PDF contains too many annotations to inspect safely."
                )
            }
            scannedAnnotationCount = nextScannedCount.partialValue
            for (index, annotation) in annotations.enumerated() {
                if index.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                if let resultLimit,
                   results.count >= resultLimit {
                    return results
                }
                let type = normalizedAnnotationType(annotation)
                let capabilities = annotationCapabilities(
                    annotation,
                    type: type
                )
                results.append(
                    PDFAnnotationSnapshot(
                        pageIndex: pageIndex,
                        annotationIndex: index,
                        type: type,
                        contents: annotation.contents,
                        generatedKind:
                            PDFGeneratedAnnotationKind.resolve(
                                author: annotation.userName
                            ),
                        color: inkColor(
                            from: annotationStyleColor(
                                annotation,
                                type: type
                            )
                        ),
                        lineWidth: annotation.border.map {
                            Double($0.lineWidth)
                        },
                        hasAppearanceStream:
                            annotation.hasAppearanceStream,
                        canEditContents: capabilities.contents,
                        canEditStyle: capabilities.style,
                        canRemove: true,
                        mutationIdentity:
                            annotationMutationIdentity(annotation)
                    )
                )
            }
        }
        return results
    }

    func containsSignature(in url: URL) throws -> Bool {
        guard let document = PDFDocument(url: url),
              !document.isLocked
        else {
            throw PaperPathError.unreadablePDF
        }
        try Self.requireSupportedPageCount(document.pageCount)
        var scannedAnnotationCount = 0
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            let annotations = page.annotations
            guard annotations.count <= Self.maximumAnnotationsPerPage
            else {
                throw PaperPathError.insufficientSelection(
                    "A PDF page contains too many annotations to inspect safely."
                )
            }
            let nextScannedCount = scannedAnnotationCount
                .addingReportingOverflow(annotations.count)
            guard !nextScannedCount.overflow,
                  nextScannedCount.partialValue
                    <= Self.maximumAnnotationsScanned
            else {
                throw PaperPathError.insufficientSelection(
                    "This PDF contains too many annotations to inspect safely."
                )
            }
            scannedAnnotationCount = nextScannedCount.partialValue
            for (index, annotation) in annotations.enumerated() {
                if index.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                if normalizedAnnotationType(annotation)
                    .caseInsensitiveCompare("ink") == .orderedSame,
                   annotation.contents == "Signature" {
                    return true
                }
            }
        }
        return false
    }

    func links(
        in url: URL,
        pageIndex requestedPageIndex: Int? = nil
    ) throws -> [PDFLinkAnnotationSnapshot] {
        guard let document = PDFDocument(url: url),
              !document.isLocked
        else {
            throw PaperPathError.unreadablePDF
        }
        try Self.requireSupportedPageCount(document.pageCount)
        if let requestedPageIndex,
           requestedPageIndex < 0
            || requestedPageIndex >= document.pageCount {
            throw PaperPathError.invalidPage
        }
        let pageIndices = requestedPageIndex.map { [$0] }
            ?? Array(0..<document.pageCount)
        var results: [PDFLinkAnnotationSnapshot] = []
        var scannedAnnotationCount = 0
        for pageIndex in pageIndices {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            let pageBounds = page.bounds(for: .cropBox)
            guard pageBounds.width > 0, pageBounds.height > 0 else {
                throw PaperPathError.invalidPage
            }
            let annotations = page.annotations
            guard annotations.count <= Self.maximumAnnotationsPerPage
            else {
                throw PaperPathError.insufficientSelection(
                    "A PDF page contains too many annotations to inspect safely."
                )
            }
            let nextScannedCount = scannedAnnotationCount
                .addingReportingOverflow(annotations.count)
            guard !nextScannedCount.overflow,
                  nextScannedCount.partialValue
                    <= Self.maximumAnnotationsScanned
            else {
                throw PaperPathError.insufficientSelection(
                    "This PDF contains too many annotations to inspect safely."
                )
            }
            scannedAnnotationCount = nextScannedCount.partialValue
            for (annotationIndex, annotation) in
                annotations.enumerated() {
                if annotationIndex.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                guard isLink(annotation) else { continue }
                let target = linkTarget(
                    annotation,
                    document: document
                )
                let bounds = annotation.bounds.intersection(pageBounds)
                guard !bounds.isNull,
                      bounds.width >= 4,
                      bounds.height >= 4
                else { continue }
                let normalizedBounds = PDFNormalizedRect(
                    x: (bounds.minX - pageBounds.minX)
                        / pageBounds.width,
                    y: (pageBounds.maxY - bounds.maxY)
                        / pageBounds.height,
                    width: bounds.width / pageBounds.width,
                    height: bounds.height / pageBounds.height
                )
                let storedTitle = annotation.contents?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                results.append(
                    PDFLinkAnnotationSnapshot(
                        pageIndex: pageIndex,
                        annotationIndex: annotationIndex,
                        normalizedBounds: normalizedBounds,
                        title: storedTitle.flatMap {
                            $0.isEmpty ? nil : $0
                        } ?? target.title,
                        target: target
                    )
                )
            }
        }
        return results
    }

    func applyLinkMutation(
        _ mutation: PDFLinkMutation,
        in url: URL
    ) throws {
        try mutate(url: url) { document in
            let pageIndex: Int
            let annotationIndex: Int
            switch mutation {
            case .update(let payload):
                pageIndex = payload.pageIndex
                annotationIndex = payload.annotationIndex
            case .remove(let value, let index):
                pageIndex = value
                annotationIndex = index
            }
            guard let page = document.page(at: pageIndex),
                  page.annotations.indices.contains(annotationIndex)
            else {
                throw PaperPathError.invalidPage
            }
            let annotation = page.annotations[annotationIndex]
            guard isLink(annotation) else {
                throw PaperPathError.insufficientSelection(
                    "The selected annotation is no longer a link."
                )
            }

            switch mutation {
            case .remove:
                page.removeAnnotation(annotation)
            case .update(let payload):
                let title = payload.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard Self.isSafeSingleLineText(
                    title,
                    maximumCharacters: 240,
                    maximumBytes: 1_024
                ),
                      Self.isValidNormalizedRect(payload.normalizedBounds)
                else {
                    throw PaperPathError.insufficientSelection(
                        "Use a link label between 1 and 240 characters."
                    )
                }
                let pageBounds = page.bounds(for: .cropBox)
                guard Self.hasValidPageBounds(pageBounds) else {
                    throw PaperPathError.invalidPage
                }
                let normalized = payload.normalizedBounds
                let bounds = CGRect(
                    x: pageBounds.minX
                        + normalized.x * pageBounds.width,
                    y: pageBounds.maxY
                        - (normalized.y + normalized.height)
                        * pageBounds.height,
                    width: normalized.width * pageBounds.width,
                    height: normalized.height * pageBounds.height
                ).intersection(pageBounds)
                guard bounds.width >= 18, bounds.height >= 12 else {
                    throw PaperPathError.insufficientSelection(
                        "Keep the link area fully inside the page."
                    )
                }
                annotation.bounds = bounds
                annotation.contents = title
                switch payload.target {
                case .web(let linkURL):
                    guard Self.isSupportedWebURL(linkURL) else {
                        throw PaperPathError.insufficientSelection(
                            "Use a valid HTTP or HTTPS address."
                        )
                    }
                    annotation.destination = nil
                    annotation.url = linkURL
                    annotation.action = PDFActionURL(url: linkURL)
                case .page(let targetPageIndex):
                    guard let targetPage = document.page(
                        at: targetPageIndex
                    ) else {
                        throw PaperPathError.invalidPage
                    }
                    let targetBounds = targetPage.bounds(for: .cropBox)
                    guard Self.hasValidPageBounds(targetBounds) else {
                        throw PaperPathError.invalidPage
                    }
                    let destination = PDFDestination(
                        page: targetPage,
                        at: CGPoint(
                            x: targetBounds.minX,
                            y: targetBounds.maxY
                        )
                    )
                    annotation.url = nil
                    annotation.destination = destination
                    annotation.action = PDFActionGoTo(
                        destination: destination
                    )
                case .unsupported:
                    throw PaperPathError.insufficientSelection(
                        "This link action is preserved but cannot be edited."
                    )
                }
            }
        }
    }

    func rotatePage(
        at index: Int,
        direction: RotationDirection = .clockwise,
        in url: URL
    ) throws {
        try mutate(url: url) { document in
            guard let page = document.page(at: index) else {
                throw PaperPathError.invalidPage
            }
            page.rotation = (
                page.rotation + direction.degrees + 360
            ) % 360
        }
    }

    func rotatePages(
        at indices: [Int],
        direction: RotationDirection = .clockwise,
        in url: URL
    ) throws {
        try Self.requireBoundedSelection(indices)
        let unique = Array(Set(indices)).sorted()
        guard !unique.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one page to rotate."
            )
        }
        try mutate(url: url) { document in
            guard unique.allSatisfy({
                $0 >= 0 && $0 < document.pageCount
            }) else {
                throw PaperPathError.invalidPage
            }
            for index in unique {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else {
                    throw PaperPathError.invalidPage
                }
                page.rotation = (
                    page.rotation + direction.degrees + 360
                ) % 360
            }
        }
    }

    func duplicatePage(at index: Int, in url: URL) throws {
        try duplicatePages(at: [index], in: url)
    }

    func duplicatePages(
        at indices: [Int],
        in url: URL
    ) throws {
        try Self.requireBoundedSelection(indices)
        let unique = Array(Set(indices)).sorted(by: >)
        guard !unique.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one page to duplicate."
            )
        }
        try mutate(url: url) { document in
            let (resultPageCount, overflow) = document.pageCount
                .addingReportingOverflow(unique.count)
            guard !overflow,
                  resultPageCount <= Self.maximumPageCount
            else {
                throw PaperPathError.insufficientSelection(
                    "The duplicated pages would exceed the 100,000-page limit."
                )
            }
            guard unique.allSatisfy({
                $0 >= 0 && $0 < document.pageCount
            }) else {
                throw PaperPathError.invalidPage
            }
            for index in unique {
                try Task.checkCancellation()
                guard let copy = document.page(at: index)?
                    .copy() as? PDFPage
                else {
                    throw PaperPathError.invalidPage
                }
                document.insert(copy, at: index + 1)
            }
        }
    }

    func deletePage(at index: Int, in url: URL) throws {
        try mutate(url: url) { document in
            guard document.pageCount > 1 else {
                throw PaperPathError.cannotDeleteOnlyPage
            }
            guard document.page(at: index) != nil else {
                throw PaperPathError.invalidPage
            }
            document.removePage(at: index)
        }
    }

    func deletePages(
        at indices: [Int],
        in url: URL
    ) throws {
        try Self.requireBoundedSelection(indices)
        let unique = Array(Set(indices)).sorted(by: >)
        guard !unique.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one page to remove."
            )
        }
        try mutate(url: url) { document in
            guard unique.count < document.pageCount else {
                throw PaperPathError.cannotDeleteOnlyPage
            }
            guard unique.allSatisfy({
                $0 >= 0 && $0 < document.pageCount
            }) else {
                throw PaperPathError.invalidPage
            }
            for index in unique {
                try Task.checkCancellation()
                document.removePage(at: index)
            }
        }
    }

    func movePage(
        at index: Int,
        direction: MoveDirection,
        in url: URL
    ) throws {
        try mutate(url: url) { document in
            let target = direction == .earlier ? index - 1 : index + 1
            guard index >= 0,
                  target >= 0,
                  index < document.pageCount,
                  target < document.pageCount
            else {
                throw PaperPathError.invalidPage
            }
            document.exchangePage(at: index, withPageAt: target)
        }
    }

    func movePage(
        from sourceIndex: Int,
        to destinationIndex: Int,
        in url: URL
    ) throws {
        try mutate(url: url) { document in
            guard sourceIndex >= 0,
                  destinationIndex >= 0,
                  sourceIndex < document.pageCount,
                  destinationIndex < document.pageCount,
                  let page = document.page(at: sourceIndex)?.copy() as? PDFPage
            else {
                throw PaperPathError.invalidPage
            }
            guard sourceIndex != destinationIndex else { return }
            document.removePage(at: sourceIndex)
            document.insert(
                page,
                at: min(destinationIndex, document.pageCount)
            )
        }
    }

    func reorderPages(
        order: [Int],
        in url: URL
    ) throws {
        try mutate(url: url) { document in
            let expected = Array(0..<document.pageCount)
            guard order.count == document.pageCount,
                  order.sorted() == expected
            else {
                throw PaperPathError.insufficientSelection(
                    "The page order must include every page exactly once."
                )
            }
            guard order != expected else { return }
            let pages = try order.map { index -> PDFPage in
                try Task.checkCancellation()
                guard let page = document.page(at: index)?
                    .copy() as? PDFPage
                else {
                    throw PaperPathError.invalidPage
                }
                return page
            }
            while document.pageCount > 0 {
                document.removePage(at: document.pageCount - 1)
            }
            for page in pages {
                document.insert(page, at: document.pageCount)
            }
        }
    }

    func replacePage(
        at destinationIndex: Int,
        withPageAt sourceIndex: Int,
        from sourceURL: URL,
        in destinationURL: URL
    ) throws {
        try mutate(url: destinationURL) { destination in
            guard let source = PDFDocument(url: sourceURL),
                  !source.isLocked,
                  destinationIndex >= 0,
                  destinationIndex < destination.pageCount,
                  sourceIndex >= 0,
                  sourceIndex < source.pageCount,
                  let replacement = source.page(at: sourceIndex)?
                    .copy() as? PDFPage
            else {
                throw PaperPathError.invalidPage
            }
            try Self.requireSupportedPageCount(source.pageCount)
            destination.removePage(at: destinationIndex)
            destination.insert(replacement, at: destinationIndex)
        }
    }

    func addInk(_ payload: PDFInkPayload, in url: URL) throws {
        try Self.validateInkPayload(payload)
        var expectedAnnotationCount: Int?
        try mutate(
            url: url,
            verification: { reopened, _ in
                guard let expectedAnnotationCount,
                      let page = reopened.page(at: payload.pageIndex),
                      page.annotations.count == expectedAnnotationCount
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the ink annotations could not be reopened"
                    )
                }
            }
        ) { document in
            guard let page = document.page(at: payload.pageIndex) else {
                throw PaperPathError.invalidPage
            }
            let pageBounds = page.bounds(for: .cropBox)
            guard Self.hasValidPageBounds(pageBounds) else {
                throw PaperPathError.invalidPage
            }
            let annotationBounds: CGRect
            switch payload.placement {
            case .page:
                annotationBounds = pageBounds
            case .signature:
                if let placement = payload.normalizedBounds {
                    annotationBounds = CGRect(
                        x: pageBounds.minX
                            + placement.x * pageBounds.width,
                        y: pageBounds.maxY
                            - (placement.y + placement.height)
                            * pageBounds.height,
                        width: placement.width * pageBounds.width,
                        height: placement.height * pageBounds.height
                    ).intersection(pageBounds)
                } else {
                    let margin = min(
                        36,
                        max(12, pageBounds.width * 0.06)
                    )
                    let availableWidth = max(
                        24,
                        pageBounds.width - margin * 2
                    )
                    let requestedWidth = pageBounds.width
                        * payload.signatureSize.pageWidthFraction
                    let width = min(
                        availableWidth,
                        max(min(120, availableWidth), requestedWidth)
                    )
                    let height = min(
                        max(36, width * 0.38),
                        max(36, pageBounds.height * 0.22)
                    )
                    let originX: CGFloat
                    switch payload.signaturePosition {
                    case .left:
                        originX = pageBounds.minX + margin
                    case .center:
                        originX = pageBounds.midX - width / 2
                    case .right:
                        originX = pageBounds.maxX - margin - width
                    }
                    annotationBounds = CGRect(
                        x: originX,
                        y: pageBounds.minY + margin,
                        width: width,
                        height: height
                    )
                }
            }
            guard Self.hasValidPageBounds(annotationBounds),
                  annotationBounds.width >= 8,
                  annotationBounds.height >= 8
            else {
                throw PaperPathError.insufficientSelection(
                    "Keep the drawing area fully inside the page."
                )
            }

            let groupedStrokes = Dictionary(
                grouping: payload.strokes
            ) { stroke in
                if payload.placement == .signature {
                    return PDFInkRenderStyle(
                        color: nil,
                        halfPointWidth: 4
                    )
                }
                let pointWidth = min(
                    max(
                        (stroke.normalizedLineWidth ?? 0.004)
                            * annotationBounds.width,
                        0.5
                    ),
                    36
                )
                return PDFInkRenderStyle(
                    color: stroke.color,
                    halfPointWidth: Int((pointWidth * 2).rounded())
                )
            }
            guard !groupedStrokes.isEmpty else {
                throw PaperPathError.insufficientSelection(
                    "Draw at least one visible stroke."
                )
            }
            expectedAnnotationCount = page.annotations.count
                + groupedStrokes.count

            for (style, strokes) in groupedStrokes {
                let annotation = PDFAnnotation(
                    bounds: annotationBounds,
                    forType: .ink,
                    withProperties: nil
                )
                annotation.color = payload.placement == .signature
                    ? .black
                    : style.color.map {
                        UIColor(
                            red: $0.red,
                            green: $0.green,
                            blue: $0.blue,
                            alpha: $0.alpha
                        )
                    } ?? .systemBlue
                annotation.contents = payload.placement == .signature
                    ? "Signature"
                    : "Drawing"
                let border = PDFBorder()
                border.lineWidth = payload.placement == .signature
                    ? 1.8
                    : CGFloat(style.halfPointWidth) / 2
                annotation.border = border

                for stroke in strokes where stroke.points.count > 1 {
                    let path = UIBezierPath()
                    for (index, point) in stroke.points.enumerated() {
                        let mapped = CGPoint(
                            x: point.x * annotationBounds.width,
                            y: (1 - point.y) * annotationBounds.height
                        )
                        if index == 0 {
                            path.move(to: mapped)
                        } else {
                            path.addLine(to: mapped)
                        }
                    }
                    annotation.add(path)
                }
                page.addAnnotation(annotation)
            }
        }
    }

    func addStamp(
        _ kind: PDFStampKind,
        toPageAt pageIndex: Int,
        in url: URL
    ) throws {
        var expectedAnnotationCount: Int?
        try mutate(
            url: url,
            verification: { document, _ in
                guard let expectedAnnotationCount,
                      let page = document.page(at: pageIndex),
                      page.annotations.count == expectedAnnotationCount,
                      page.annotations.contains(where: {
                          $0.stampName?.trimmingCharacters(
                              in: CharacterSet(charactersIn: "/")
                          ) == kind.stampName.trimmingCharacters(
                              in: CharacterSet(charactersIn: "/")
                          )
                              && $0.contents == kind.title
                              && $0.shouldDisplay
                              && $0.shouldPrint
                              && Self.hasValidPageBounds($0.bounds)
                      })
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the added stamp could not be reopened"
                    )
                }
            }
        ) { document in
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            let pageBounds = page.bounds(for: .cropBox)
            guard Self.hasValidPageBounds(pageBounds),
                  pageBounds.width >= 136,
                  pageBounds.height >= 86
            else {
                throw PaperPathError.invalidPage
            }
            let margin = min(36, max(12, pageBounds.width * 0.05))
            let width = min(180, max(112, pageBounds.width * 0.34))
            let height = min(54, max(38, width * 0.28))
            let annotationBounds = CGRect(
                x: pageBounds.maxX - margin - width,
                y: pageBounds.maxY - margin - height,
                width: width,
                height: height
            )
            guard Self.hasValidPageBounds(annotationBounds),
                  pageBounds.contains(annotationBounds)
            else {
                throw PaperPathError.invalidPage
            }
            let annotation = PDFAnnotation(
                bounds: annotationBounds,
                forType: .stamp,
                withProperties: nil
            )
            annotation.stampName = kind.stampName
            annotation.contents = kind.title
            annotation.color = stampColor(for: kind)
            let border = PDFBorder()
            border.lineWidth = 1.4
            annotation.border = border
            annotation.shouldDisplay = true
            annotation.shouldPrint = true
            expectedAnnotationCount = page.annotations.count + 1
            page.addAnnotation(annotation)
        }
    }

    func applyPageNumbers(
        _ payload: PDFPageNumberingPayload,
        in url: URL
    ) throws {
        let pageIndices = Array(Set(payload.pageIndices)).sorted()
        guard !pageIndices.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one page to number."
            )
        }
        guard pageIndices.count <= 10_000 else {
            throw PaperPathError.insufficientSelection(
                "Number up to 10,000 pages at a time."
            )
        }
        guard payload.startNumber >= 1,
              payload.startNumber
                <= 999_999 - max(0, pageIndices.count - 1)
        else {
            throw PaperPathError.insufficientSelection(
                "Use a starting number between 1 and 999,999."
            )
        }
        let lastNumber = payload.startNumber
            + pageIndices.count - 1
        let expectedText = Dictionary(
            uniqueKeysWithValues: pageIndices.enumerated().map {
                offset,
                pageIndex in
                (
                    pageIndex,
                    payload.format.text(
                        number: payload.startNumber + offset,
                        total: lastNumber
                    )
                )
            }
        )

        try mutate(
            url: url,
            verification: { document, _ in
                for pageIndex in pageIndices {
                    try Task.checkCancellation()
                    guard let page = document.page(at: pageIndex),
                          let expected = expectedText[pageIndex]
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "a numbered page is missing"
                        )
                    }
                    let generated = page.annotations.filter {
                        isGeneratedPageNumber($0)
                    }
                    guard generated.count == 1,
                          generated[0].contents == expected,
                          generated[0].shouldDisplay,
                          generated[0].shouldPrint,
                          Self.hasValidPageBounds(generated[0].bounds),
                          page.bounds(for: .cropBox).contains(
                              generated[0].bounds
                          )
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "a visible page number did not persist"
                        )
                    }
                }
            }
        ) { document in
            guard pageIndices.allSatisfy({
                $0 >= 0 && $0 < document.pageCount
            }) else {
                throw PaperPathError.invalidPage
            }
            for pageIndex in pageIndices {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex),
                      let text = expectedText[pageIndex]
                else {
                    throw PaperPathError.invalidPage
                }
                for annotation in page.annotations
                where isGeneratedPageNumber(annotation) {
                    page.removeAnnotation(annotation)
                }
                let pageBounds = page.bounds(for: .cropBox)
                guard Self.hasValidPageBounds(pageBounds),
                      pageBounds.width >= 48,
                      pageBounds.height >= 48
                else {
                    throw PaperPathError.invalidPage
                }
                let annotation = PDFAnnotation(
                    bounds: pageNumberBounds(
                        position: payload.position,
                        pageBounds: pageBounds,
                        text: text
                    ),
                    forType: .freeText,
                    withProperties: nil
                )
                annotation.contents = text
                annotation.font = UIFont.monospacedDigitSystemFont(
                    ofSize: min(
                        12,
                        max(9, pageBounds.height * 0.015)
                    ),
                    weight: .medium
                )
                annotation.fontColor = UIColor.black
                    .withAlphaComponent(0.78)
                annotation.color = .clear
                annotation.backgroundColor = .clear
                annotation.alignment = textAlignment(
                    for: payload.position
                )
                annotation.userName =
                    PDFGeneratedAnnotationKind.pageNumber.author
                annotation.modificationDate = Date()
                annotation.shouldDisplay = true
                annotation.shouldPrint = true
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
                page.addAnnotation(annotation)
            }
        }
    }

    func removeGeneratedPageNumbers(in url: URL) throws -> Int {
        var removedCount = 0
        try mutate(
            url: url,
            verification: { document, _ in
                for pageIndex in 0..<document.pageCount {
                    try Task.checkCancellation()
                    guard let page = document.page(at: pageIndex)
                    else { throw PaperPathError.invalidPage }
                    guard !page.annotations.contains(
                        where: isGeneratedPageNumber
                    ) else {
                        throw PaperPathError.outputVerificationFailed(
                            "a generated page number remains"
                        )
                    }
                }
            }
        ) { document in
            for pageIndex in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex)
                else { throw PaperPathError.invalidPage }
                for annotation in page.annotations
                where isGeneratedPageNumber(annotation) {
                    page.removeAnnotation(annotation)
                    removedCount += 1
                }
            }
            guard removedCount > 0 else {
                throw PaperPathError.insufficientSelection(
                    "No PaperPath page numbers were found."
                )
            }
        }
        return removedCount
    }

    func applyBatesNumbers(
        _ payload: PDFBatesNumberingPayload,
        in url: URL
    ) throws {
        let pageIndices = Array(Set(payload.pageIndices)).sorted()
        guard !pageIndices.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one page for Bates numbering."
            )
        }
        guard pageIndices.count <= 10_000 else {
            throw PaperPathError.insufficientSelection(
                "Bates number up to 10,000 pages at a time."
            )
        }
        guard (3...15).contains(payload.digitCount) else {
            throw PaperPathError.insufficientSelection(
                "Use between 3 and 15 digits."
            )
        }
        let prefix = try PDFBatesNumberingPayload.normalizedAffix(
            payload.prefix,
            name: "prefix"
        )
        let suffix = try PDFBatesNumberingPayload.normalizedAffix(
            payload.suffix,
            name: "suffix"
        )
        let maximumNumber = PDFBatesNumberingPayload
            .maximumNumber(digitCount: payload.digitCount)
        let pageOffset = Int64(pageIndices.count - 1)
        guard payload.startNumber >= 1,
              payload.startNumber <= maximumNumber - pageOffset
        else {
            throw PaperPathError.insufficientSelection(
                "The Bates sequence does not fit the selected digit width."
            )
        }
        let expectedText = Dictionary(
            uniqueKeysWithValues: pageIndices.enumerated().map {
                offset,
                pageIndex in
                (
                    pageIndex,
                    PDFBatesNumberingPayload.text(
                        number: payload.startNumber + Int64(offset),
                        digitCount: payload.digitCount,
                        prefix: prefix,
                        suffix: suffix
                    )
                )
            }
        )
        let selectedPageSet = Set(pageIndices)
        let expectedIdentifiers = Set(expectedText.values)

        try mutate(
            url: url,
            verification: { document, _ in
                for pageIndex in pageIndices {
                    try Task.checkCancellation()
                    guard let page = document.page(at: pageIndex),
                          let expected = expectedText[pageIndex]
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "a Bates-numbered page is missing"
                        )
                    }
                    let generated = page.annotations.filter {
                        isGeneratedBatesNumber($0)
                    }
                    guard generated.count == 1,
                          generated[0].contents == expected,
                          generated[0].shouldDisplay,
                          generated[0].shouldPrint,
                          Self.hasValidPageBounds(generated[0].bounds),
                          page.bounds(for: .cropBox).contains(
                              generated[0].bounds
                          )
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "a Bates number did not persist"
                        )
                    }
                }
            }
        ) { document in
            guard pageIndices.allSatisfy({
                $0 >= 0 && $0 < document.pageCount
            }) else {
                throw PaperPathError.invalidPage
            }
            for pageIndex in 0..<document.pageCount
            where !selectedPageSet.contains(pageIndex) {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex)
                else { throw PaperPathError.invalidPage }
                let hasCollision = page.annotations.contains {
                    isGeneratedBatesNumber($0)
                        && $0.contents.map(
                            expectedIdentifiers.contains
                        ) == true
                }
                guard !hasCollision else {
                    throw PaperPathError.insufficientSelection(
                        "The Bates sequence duplicates an existing PaperPath identifier."
                    )
                }
            }
            for pageIndex in pageIndices {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex),
                      let text = expectedText[pageIndex]
                else {
                    throw PaperPathError.invalidPage
                }
                for annotation in page.annotations
                where isGeneratedBatesNumber(annotation) {
                    page.removeAnnotation(annotation)
                }
                let pageBounds = page.bounds(for: .cropBox)
                guard Self.hasValidPageBounds(pageBounds),
                      pageBounds.width >= 72,
                      pageBounds.height >= 72
                else {
                    throw PaperPathError.invalidPage
                }
                let bounds = pageNumberBounds(
                    position: payload.position,
                    pageBounds: pageBounds,
                    text: text
                )
                guard let fontSize = batesFontSize(
                    text: text,
                    bounds: bounds,
                    pageBounds: pageBounds
                ) else {
                    throw PaperPathError.insufficientSelection(
                        "The Bates number is too long for one or more pages."
                    )
                }
                let annotation = PDFAnnotation(
                    bounds: bounds,
                    forType: .freeText,
                    withProperties: nil
                )
                annotation.contents = text
                annotation.font = UIFont.monospacedDigitSystemFont(
                    ofSize: fontSize,
                    weight: .semibold
                )
                annotation.fontColor = UIColor.black
                    .withAlphaComponent(0.84)
                annotation.color = .clear
                annotation.backgroundColor = .clear
                annotation.alignment = textAlignment(
                    for: payload.position
                )
                annotation.userName =
                    PDFGeneratedAnnotationKind.batesNumber.author
                annotation.modificationDate = Date()
                annotation.shouldDisplay = true
                annotation.shouldPrint = true
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
                page.addAnnotation(annotation)
            }
        }
    }

    func removeGeneratedBatesNumbers(in url: URL) throws -> Int {
        var removedCount = 0
        var expectedSurvivors: [Int: [String]] = [:]
        try mutate(
            url: url,
            verification: { document, _ in
                for pageIndex in 0..<document.pageCount {
                    try Task.checkCancellation()
                    guard let page = document.page(at: pageIndex)
                    else { throw PaperPathError.invalidPage }
                    guard !page.annotations.contains(
                        where: isGeneratedBatesNumber
                    ),
                          page.annotations.map(
                              annotationRemovalSignature
                          ).sorted() == expectedSurvivors[pageIndex]
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "a generated Bates number remains or another annotation changed"
                        )
                    }
                }
            }
        ) { document in
            for pageIndex in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex)
                else { throw PaperPathError.invalidPage }
                expectedSurvivors[pageIndex] = page.annotations
                    .filter { !isGeneratedBatesNumber($0) }
                    .map(annotationRemovalSignature)
                    .sorted()
                for annotation in page.annotations
                where isGeneratedBatesNumber(annotation) {
                    page.removeAnnotation(annotation)
                    removedCount += 1
                }
            }
            guard removedCount > 0 else {
                throw PaperPathError.insufficientSelection(
                    "No PaperPath Bates numbers were found."
                )
            }
        }
        return removedCount
    }

    func applyWatermark(
        _ payload: PDFWatermarkPayload,
        in url: URL
    ) throws {
        let pageIndices = Array(Set(payload.pageIndices)).sorted()
        guard !pageIndices.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one page to watermark."
            )
        }
        guard pageIndices.count <= 10_000 else {
            throw PaperPathError.insufficientSelection(
                "Watermark up to 10,000 pages at a time."
            )
        }
        let text = try normalizedWatermarkText(payload.text)
        let expectedRotation = payload.layout.rotationDegrees

        try mutate(
            url: url,
            verification: { document, _ in
                for pageIndex in pageIndices {
                    try Task.checkCancellation()
                    guard let page = document.page(at: pageIndex)
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "a watermarked page is missing"
                        )
                    }
                    let generated = page.annotations.filter {
                        isGeneratedWatermark($0)
                    }
                    guard generated.count == 1,
                          generated[0].contents == text,
                          generated[0].shouldDisplay,
                          generated[0].shouldPrint,
                          Self.hasValidPageBounds(generated[0].bounds),
                          page.bounds(for: .cropBox).contains(
                              generated[0].bounds
                          ),
                          annotationRotation(generated[0])
                            == expectedRotation,
                          abs(
                            annotationOpacity(generated[0])
                                - payload.intensity.opacity
                          ) <= 0.01
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "a generated watermark did not persist"
                        )
                    }
                }
            }
        ) { document in
            guard pageIndices.allSatisfy({
                $0 >= 0 && $0 < document.pageCount
            }) else {
                throw PaperPathError.invalidPage
            }
            for pageIndex in pageIndices {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex)
                else {
                    throw PaperPathError.invalidPage
                }
                for annotation in page.annotations
                where isGeneratedWatermark(annotation) {
                    page.removeAnnotation(annotation)
                }
                let pageBounds = page.bounds(for: .cropBox)
                guard Self.hasValidPageBounds(pageBounds),
                      pageBounds.width >= 72,
                      pageBounds.height >= 72
                else {
                    throw PaperPathError.invalidPage
                }
                let annotation = PDFAnnotation(
                    bounds: watermarkBounds(
                        layout: payload.layout,
                        intensity: payload.intensity,
                        pageBounds: pageBounds
                    ),
                    forType: .freeText,
                    withProperties: nil
                )
                annotation.contents = text
                annotation.font = UIFont.systemFont(
                    ofSize: watermarkFontSize(
                        layout: payload.layout,
                        intensity: payload.intensity,
                        pageBounds: pageBounds,
                        textLength: text.count
                    ),
                    weight: payload.intensity == .bold
                        ? .bold
                        : .semibold
                )
                annotation.fontColor = watermarkColor(
                    payload.tone,
                    opacity: payload.intensity.opacity
                )
                annotation.color = .clear
                annotation.backgroundColor = .clear
                annotation.alignment = .center
                annotation.userName =
                    PDFGeneratedAnnotationKind.watermark.author
                annotation.modificationDate = Date()
                annotation.shouldDisplay = true
                annotation.shouldPrint = true
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
                // PDFKit reserves /CA for widget captions, so persist the
                // intended opacity under a namespaced annotation key.
                guard annotation.setValue(
                    NSNumber(value: payload.intensity.opacity),
                    forAnnotationKey: PDFAnnotationKey(
                        rawValue: "PaperPathOpacity"
                    )
                ) else {
                    throw PaperPathError.storageFailure(
                        "The watermark opacity could not be encoded."
                    )
                }
                if expectedRotation != 0 {
                    guard annotation.setValue(
                        NSNumber(value: expectedRotation),
                        forAnnotationKey: PDFAnnotationKey(
                            rawValue: "Rotate"
                        )
                    ) else {
                        throw PaperPathError.storageFailure(
                            "The watermark angle could not be encoded."
                        )
                    }
                }
                page.addAnnotation(annotation)
            }
        }
    }

    func removeGeneratedWatermarks(in url: URL) throws -> Int {
        var removedCount = 0
        try mutate(
            url: url,
            verification: { document, _ in
                for pageIndex in 0..<document.pageCount {
                    try Task.checkCancellation()
                    guard let page = document.page(at: pageIndex)
                    else { throw PaperPathError.invalidPage }
                    guard !page.annotations.contains(
                        where: isGeneratedWatermark
                    ) else {
                        throw PaperPathError.outputVerificationFailed(
                            "a generated watermark remains"
                        )
                    }
                }
            }
        ) { document in
            for pageIndex in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex)
                else { throw PaperPathError.invalidPage }
                for annotation in page.annotations
                where isGeneratedWatermark(annotation) {
                    page.removeAnnotation(annotation)
                    removedCount += 1
                }
            }
            guard removedCount > 0 else {
                throw PaperPathError.insufficientSelection(
                    "No PaperPath watermarks were found."
                )
            }
        }
        return removedCount
    }

    func addFormField(
        _ payload: PDFFormFieldPayload,
        in url: URL
    ) throws {
        guard payload.kind.canCreate else {
            throw PaperPathError.insufficientSelection(
                "This form field type cannot be created safely."
            )
        }
        let trimmedName = payload.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard Self.isSafeSingleLineText(
            trimmedName,
            maximumCharacters: 80,
            maximumBytes: 512
        ),
              Self.isValidNormalizedRect(payload.normalizedBounds)
        else {
            throw PaperPathError.insufficientSelection(
                "Use a field name between 1 and 80 characters."
            )
        }
        if let maximumLength = payload.maximumLength {
            guard payload.kind == .text,
                  (1...4_000).contains(maximumLength)
            else {
                throw PaperPathError.insufficientSelection(
                    "Use a text field limit between 1 and 4,000 characters."
                )
            }
        }
        let options = payload.options.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if payload.kind == .radio || payload.kind == .choice {
            guard (2...12).contains(options.count),
                  Set(options.map {
                      $0.folding(
                          options: [
                              .caseInsensitive,
                              .diacriticInsensitive,
                              .widthInsensitive
                          ],
                          locale: .current
                      )
                  }).count
                    == options.count,
                  options.allSatisfy({
                      Self.isSafeSingleLineText(
                          $0,
                          maximumCharacters: 64,
                          maximumBytes: 256
                      )
                  })
            else {
                throw PaperPathError.insufficientSelection(
                    "Use 2 to 12 unique options, up to 64 characters each."
                )
            }
        }
        var expectedAnnotationCount: Int?
        let expectedWidgetCount = payload.kind == .radio
            ? options.count
            : 1
        try mutate(
            url: url,
            verification: { reopened, _ in
                guard let expectedAnnotationCount,
                      let page = reopened.page(at: payload.pageIndex),
                      page.annotations.count == expectedAnnotationCount
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the created form field could not be reopened"
                    )
                }
                let matchingWidgets = page.annotations.filter {
                    $0.fieldName?.caseInsensitiveCompare(
                        trimmedName
                    ) == .orderedSame
                }
                guard matchingWidgets.count == expectedWidgetCount else {
                    throw PaperPathError.outputVerificationFailed(
                        "the created form widgets did not match the request"
                    )
                }
            }
        ) { document in
            guard let page = document.page(at: payload.pageIndex) else {
                throw PaperPathError.invalidPage
            }
            var duplicate = false
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let candidatePage = document.page(at: index) else {
                    throw PaperPathError.invalidPage
                }
                if candidatePage.annotations.contains(where: {
                    let name = $0.fieldName
                        ?? $0.value(
                            forAnnotationKey: .textLabel
                        ) as? String
                    return name?.caseInsensitiveCompare(trimmedName)
                        == .orderedSame
                }) {
                    duplicate = true
                    break
                }
            }
            guard !duplicate else {
                throw PaperPathError.insufficientSelection(
                    "A form field named “\(trimmedName)” already exists."
                )
            }
            let pageBounds = page.bounds(for: .cropBox)
            guard Self.hasValidPageBounds(pageBounds) else {
                throw PaperPathError.invalidPage
            }
            let normalized = payload.normalizedBounds
            let fieldBounds = CGRect(
                x: pageBounds.minX + normalized.x * pageBounds.width,
                y: pageBounds.maxY
                    - (normalized.y + normalized.height)
                    * pageBounds.height,
                width: normalized.width * pageBounds.width,
                height: normalized.height * pageBounds.height
            ).intersection(pageBounds)
            guard fieldBounds.width >= 18,
                  fieldBounds.height >= 18,
                  fieldBounds.width <= pageBounds.width,
                  fieldBounds.height <= pageBounds.height
            else {
                throw PaperPathError.insufficientSelection(
                    "Place the field fully inside the page."
                )
            }
            let addedAnnotationCount = payload.kind == .radio
                ? options.count * 2
                : 1
            expectedAnnotationCount = page.annotations.count
                + addedAnnotationCount

            func widget(bounds: CGRect) -> PDFAnnotation {
                let annotation = PDFAnnotation(
                    bounds: bounds,
                    forType: .widget,
                    withProperties: nil
                )
                annotation.color = .systemBlue
                annotation.backgroundColor = UIColor.white
                    .withAlphaComponent(0.92)
                let border = PDFBorder()
                border.lineWidth = 1
                border.style = .solid
                annotation.border = border
                return annotation
            }

            func applyRequiredFlag(
                to annotation: PDFAnnotation
            ) throws {
                guard payload.isRequired else { return }
                let flags = (
                    annotation.value(
                        forAnnotationKey: .widgetFieldFlags
                    ) as? NSNumber
                )?.intValue ?? 0
                guard annotation.setValue(
                    NSNumber(value: flags | 2),
                    forAnnotationKey: .widgetFieldFlags
                ) else {
                    throw PaperPathError.storageFailure(
                        "The required field flag could not be encoded."
                    )
                }
            }

            switch payload.kind {
            case .text:
                let annotation = widget(bounds: fieldBounds)
                annotation.widgetFieldType = .text
                annotation.widgetStringValue = ""
                annotation.widgetDefaultStringValue = ""
                annotation.isMultiline = payload.isMultiline
                annotation.maximumLength = payload.maximumLength ?? 0
                annotation.font = UIFont(
                    name: "Helvetica",
                    size: 12
                )
                annotation.fontColor = .black
                try applyRequiredFlag(to: annotation)
                annotation.fieldName = trimmedName
                page.addAnnotation(annotation)
            case .checkbox:
                let annotation = widget(bounds: fieldBounds)
                annotation.widgetFieldType = .button
                annotation.widgetControlType = .checkBoxControl
                annotation.buttonWidgetState = .offState
                annotation.buttonWidgetStateString = "Off"
                annotation.caption = trimmedName
                try applyRequiredFlag(to: annotation)
                annotation.fieldName = trimmedName
                page.addAnnotation(annotation)
            case .radio:
                let rowHeight = fieldBounds.height
                    / CGFloat(options.count)
                let controlSize = min(18, rowHeight - 4)
                guard rowHeight >= 18,
                      fieldBounds.width - controlSize - 6 >= 24
                else {
                    throw PaperPathError.insufficientSelection(
                        "Make the radio group taller and wider for its options."
                    )
                }
                for (index, option) in options.enumerated() {
                    let rowMinY = fieldBounds.maxY
                        - rowHeight * CGFloat(index + 1)
                    let controlBounds = CGRect(
                        x: fieldBounds.minX,
                        y: rowMinY + (rowHeight - controlSize) / 2,
                        width: controlSize,
                        height: controlSize
                    )
                    let annotation = widget(bounds: controlBounds)
                    annotation.widgetFieldType = .button
                    annotation.widgetControlType = .radioButtonControl
                    annotation.allowsToggleToOff = false
                    annotation.radiosInUnison = false
                    annotation.buttonWidgetState = .offState
                    annotation.buttonWidgetStateString =
                        "Option\(index + 1)"
                    annotation.caption = ""
                    try applyRequiredFlag(to: annotation)
                    annotation.fieldName = trimmedName
                    page.addAnnotation(annotation)

                    let label = PDFAnnotation(
                        bounds: CGRect(
                            x: controlBounds.maxX + 6,
                            y: rowMinY,
                            width: fieldBounds.maxX
                                - controlBounds.maxX - 6,
                            height: rowHeight
                        ),
                        forType: .freeText,
                        withProperties: nil
                    )
                    label.contents = option
                    label.font = UIFont(
                        name: "Helvetica",
                        size: min(12, max(9, rowHeight * 0.46))
                    )
                    label.fontColor = .black
                    label.color = .clear
                    label.backgroundColor = .clear
                    let labelBorder = PDFBorder()
                    labelBorder.lineWidth = 0
                    label.border = labelBorder
                    page.addAnnotation(label)
                }
            case .choice:
                let annotation = widget(bounds: fieldBounds)
                annotation.widgetFieldType = .choice
                annotation.isListChoice = payload.isListChoice
                annotation.choices = options
                annotation.values = options
                annotation.widgetStringValue = ""
                annotation.widgetDefaultStringValue = ""
                annotation.font = UIFont(
                    name: "Helvetica",
                    size: 12
                )
                annotation.fontColor = .black
                try applyRequiredFlag(to: annotation)
                annotation.fieldName = trimmedName
                page.addAnnotation(annotation)
            case .signature:
                let annotation = widget(bounds: fieldBounds)
                annotation.widgetFieldType = .signature
                annotation.caption = trimmedName
                annotation.contents = "Signature field"
                try applyRequiredFlag(to: annotation)
                annotation.fieldName = trimmedName
                page.addAnnotation(annotation)
            default:
                throw PaperPathError.insufficientSelection(
                    "This form field type cannot be created safely."
                )
            }
        }
    }

    func insertBlankPage(
        at insertionIndex: Int,
        in url: URL
    ) throws {
        try mutate(url: url) { document in
            guard document.pageCount > 0,
                  document.pageCount < Self.maximumPageCount,
                  insertionIndex >= 0,
                  insertionIndex <= document.pageCount,
                  let reference = document.page(
                    at: min(insertionIndex, document.pageCount - 1)
                  )
            else {
                throw PaperPathError.invalidPage
            }
            let mediaBounds = reference.bounds(for: .mediaBox)
            let cropBounds = reference.bounds(for: .cropBox)
            guard mediaBounds.width.isFinite,
                  mediaBounds.height.isFinite,
                  mediaBounds.width > 0,
                  mediaBounds.height > 0,
                  cropBounds.width.isFinite,
                  cropBounds.height.isFinite,
                  cropBounds.width > 0,
                  cropBounds.height > 0
            else {
                throw PaperPathError.invalidPage
            }
            let page = PDFPage()
            page.setBounds(mediaBounds, for: .mediaBox)
            page.setBounds(cropBounds, for: .cropBox)
            page.rotation = reference.rotation
            document.insert(page, at: insertionIndex)
        }
    }

    func insertBlankPage(after index: Int, in url: URL) throws {
        guard index >= 0 else {
            throw PaperPathError.invalidPage
        }
        try insertBlankPage(at: index + 1, in: url)
    }

    func appendPages(from sourceURL: URL, in url: URL) throws {
        try mutate(url: url) { document in
            guard let source = PDFDocument(url: sourceURL),
                  !source.isLocked
            else {
                throw PaperPathError.unreadablePDF
            }
            try Self.requireSupportedPageCount(source.pageCount)
            let (resultPageCount, overflow) = document.pageCount
                .addingReportingOverflow(source.pageCount)
            guard !overflow,
                  resultPageCount <= Self.maximumPageCount
            else {
                throw PaperPathError.insufficientSelection(
                    "The appended pages would exceed the 100,000-page limit."
                )
            }
            for index in 0..<source.pageCount {
                try Task.checkCancellation()
                guard let page = source.page(at: index)?.copy() as? PDFPage else {
                    throw PaperPathError.invalidPage
                }
                document.insert(page, at: document.pageCount)
            }
        }
    }

    func appendPages(
        from sourceURL: URL,
        indices: [Int],
        in url: URL
    ) throws {
        try Self.requireBoundedSelection(indices)
        let unique = Array(Set(indices)).sorted()
        guard !unique.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one page to copy."
            )
        }
        try mutate(url: url) { document in
            guard let source = PDFDocument(url: sourceURL),
                  !source.isLocked,
                  unique.allSatisfy({
                      $0 >= 0 && $0 < source.pageCount
                  })
            else {
                throw PaperPathError.unreadablePDF
            }
            try Self.requireSupportedPageCount(source.pageCount)
            let (resultPageCount, overflow) = document.pageCount
                .addingReportingOverflow(unique.count)
            guard !overflow,
                  resultPageCount <= Self.maximumPageCount
            else {
                throw PaperPathError.insufficientSelection(
                    "The copied pages would exceed the 100,000-page limit."
                )
            }
            for index in unique {
                try Task.checkCancellation()
                guard let page = source.page(at: index)?
                    .copy() as? PDFPage
                else {
                    throw PaperPathError.invalidPage
                }
                document.insert(page, at: document.pageCount)
            }
        }
    }

    func cropPage(
        at index: Int,
        insetFraction: Double,
        in url: URL
    ) throws {
        let inset = max(0, min(insetFraction, 0.18))
        try cropPage(
            at: index,
            insets: PDFPageCropInsets(
                top: inset,
                right: inset,
                bottom: inset,
                left: inset
            ),
            in: url
        )
    }

    func cropPage(
        at index: Int,
        insets: PDFPageCropInsets,
        in url: URL
    ) throws {
        try cropPages(
            [index: insets],
            in: url
        )
    }

    func cropPages(
        _ requestedInsets: [Int: PDFPageCropInsets],
        in url: URL
    ) throws {
        guard !requestedInsets.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one page to prepare."
            )
        }
        try mutate(url: url) { document in
            let indices = requestedInsets.keys.sorted()
            guard indices.allSatisfy({
                $0 >= 0 && $0 < document.pageCount
            }) else {
                throw PaperPathError.invalidPage
            }

            for index in indices {
                try Task.checkCancellation()
                guard let page = document.page(at: index),
                      let displayInsets = requestedInsets[index]
                else {
                    throw PaperPathError.invalidPage
                }
                let requested = displayInsets.clamped
                    .mappedToPDFBox(rotation: page.rotation)
                guard requested.isValid else {
                    throw PaperPathError.invalidPage
                }
                let bounds = page.bounds(for: .cropBox)
                let cropped = CGRect(
                    x: bounds.minX
                        + bounds.width * CGFloat(requested.left),
                    y: bounds.minY
                        + bounds.height * CGFloat(requested.bottom),
                    width: bounds.width
                        * CGFloat(requested.retainedWidth),
                    height: bounds.height
                        * CGFloat(requested.retainedHeight)
                )
                guard cropped.width > 40, cropped.height > 40 else {
                    throw PaperPathError.invalidPage
                }
                page.setBounds(cropped, for: .cropBox)
            }
        }
    }

    func pagePreparationAssessment(
        in url: URL,
        revisionID: UUID,
        progress: PDFProgressHandler = { _ in }
    ) throws -> PDFPagePreparationAssessment {
        try pagePreparationAssessment(
            in: url,
            revisionID: revisionID,
            pageIndices: nil,
            detectsContentBounds: true,
            progress: progress
        )
    }

    func pageGeometryAssessment(
        in url: URL,
        revisionID: UUID,
        pageIndices: [Int]
    ) throws -> PDFPagePreparationAssessment {
        try pagePreparationAssessment(
            in: url,
            revisionID: revisionID,
            pageIndices: pageIndices,
            detectsContentBounds: false
        )
    }

    private func pagePreparationAssessment(
        in url: URL,
        revisionID: UUID,
        pageIndices: [Int]?,
        detectsContentBounds: Bool,
        progress: PDFProgressHandler = { _ in }
    ) throws -> PDFPagePreparationAssessment {
        guard let document = PDFDocument(url: url),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        try Self.requireSupportedPageCount(document.pageCount)

        let requestedIndices: [Int]
        if let pageIndices {
            let unique = Array(Set(pageIndices)).sorted()
            guard !unique.isEmpty,
                  unique.allSatisfy({
                      $0 >= 0 && $0 < document.pageCount
                  })
            else {
                throw PaperPathError.invalidPage
            }
            requestedIndices = unique
        } else {
            requestedIndices = Array(0..<document.pageCount)
        }

        var items: [PDFPagePreparationItem] = []
        items.reserveCapacity(requestedIndices.count)
        for (offset, pageIndex) in requestedIndices.enumerated() {
            try Task.checkCancellation()
            let item: PDFPagePreparationItem = try autoreleasepool {
                guard let page = document.page(at: pageIndex) else {
                    throw PaperPathError.invalidPage
                }
                let bounds = page.bounds(for: .cropBox)
                guard bounds.width.isFinite,
                      bounds.height.isFinite,
                      bounds.width > 0,
                      bounds.height > 0
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "page \(pageIndex + 1) has invalid dimensions"
                    )
                }
                let rotation = ((page.rotation % 360) + 360) % 360
                let swapsEdges = rotation == 90 || rotation == 270
                let displaySize = swapsEdges
                    ? CGSize(width: bounds.height, height: bounds.width)
                    : bounds.size
                let detection: (
                    insets: PDFPageCropInsets,
                    confidence: PDFPageCropConfidence,
                    inkCoverage: Double
                )
                if detectsContentBounds {
                    let longestEdge: CGFloat = 420
                    let scale = longestEdge
                        / max(displaySize.width, displaySize.height)
                    let thumbnail = page.thumbnail(
                        of: CGSize(
                            width: max(
                                1,
                                displaySize.width * scale
                            ),
                            height: max(
                                1,
                                displaySize.height * scale
                            )
                        ),
                        for: .cropBox
                    )
                    detection = detectedContentBounds(in: thumbnail)
                } else {
                    detection = (.none, .low, 0)
                }
                return PDFPagePreparationItem(
                    pageIndex: pageIndex,
                    widthPoints: Double(displaySize.width),
                    heightPoints: Double(displaySize.height),
                    rotation: rotation,
                    paperClass: paperClass(for: displaySize),
                    detectedInsets: detection.insets,
                    confidence: detection.confidence,
                    inkCoverage: detection.inkCoverage
                )
            }
            items.append(item)
            progress(
                Double(offset + 1)
                    / Double(requestedIndices.count)
            )
        }
        return PDFPagePreparationAssessment(
            revisionID: revisionID,
            pages: items,
            pageCount: document.pageCount
        )
    }

    func editAnnotation(
        _ payload: PDFAnnotationEditPayload,
        in url: URL
    ) throws {
        let expectedType = payload.expectedType
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        guard payload.pageIndex >= 0,
              payload.annotationIndex >= 0,
              payload.contents.count <= 2_000,
              payload.contents.utf8.count <= 8 * 1_024,
              Self.isSafeEditableText(payload.contents),
              Self.isSafeSingleLineText(
                  expectedType,
                  maximumCharacters: 64,
                  maximumBytes: 128
              ),
              [
                payload.color.red,
                payload.color.green,
                payload.color.blue,
                payload.color.alpha
              ].allSatisfy(\.isFinite),
              payload.lineWidth.map({
                  $0.isFinite && (0.5...12).contains($0)
              }) ?? true
        else {
            throw PaperPathError.insufficientSelection(
                "The annotation edit exceeds the safe local limit."
            )
        }
        let requestedColor = PDFInkColor(
            red: min(max(payload.color.red, 0), 1),
            green: min(max(payload.color.green, 0), 1),
            blue: min(max(payload.color.blue, 0), 1),
            alpha: min(max(payload.color.alpha, 0), 1)
        )
        let color = UIColor(
            red: requestedColor.red,
            green: requestedColor.green,
            blue: requestedColor.blue,
            alpha: requestedColor.alpha
        )
        let requestedLineWidth = payload.lineWidth

        try mutate(
            url: url,
            verification: { document, _ in
                guard let page = document.page(
                    at: payload.pageIndex
                ),
                      page.annotations.indices.contains(
                          payload.annotationIndex
                      )
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the edited annotation could not be reopened"
                    )
                }
                let annotation = page.annotations[
                    payload.annotationIndex
                ]
                let type = normalizedAnnotationType(annotation)
                guard type.caseInsensitiveCompare(expectedType)
                        == .orderedSame,
                      (annotation.contents ?? "") == payload.contents
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the annotation note or type did not persist"
                    )
                }
                let capabilities = annotationCapabilities(
                    annotation,
                    type: type
                )
                if capabilities.style {
                    guard colorsMatch(
                        inkColor(
                            from: annotationStyleColor(
                                annotation,
                                type: type
                            )
                        ),
                        requestedColor
                    ) else {
                        throw PaperPathError.outputVerificationFailed(
                            "the annotation color did not persist"
                        )
                    }
                }
                if supportsLineWidth(type),
                   capabilities.style,
                   let requestedLineWidth {
                    guard abs(
                        effectiveLineWidth(annotation)
                            - requestedLineWidth
                    ) <= 0.05
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "the annotation line width did not persist"
                        )
                    }
                }
            }
        ) { document in
            guard let page = document.page(at: payload.pageIndex),
                  page.annotations.indices.contains(
                      payload.annotationIndex
                  )
            else {
                throw PaperPathError.invalidPage
            }
            let annotation = page.annotations[
                payload.annotationIndex
            ]
            let type = normalizedAnnotationType(annotation)
            let identityMatches =
                payload.expectedMutationIdentity.map {
                    expectedIdentity in
                    annotationMutationIdentity(annotation)
                        == expectedIdentity
                } ?? true
            guard type.caseInsensitiveCompare(expectedType)
                    == .orderedSame,
                  identityMatches
            else {
                throw PaperPathError.insufficientSelection(
                    "The selected annotation changed before saving."
                )
            }
            let capabilities = annotationCapabilities(
                annotation,
                type: type
            )
            guard capabilities.contents || capabilities.style else {
                throw PaperPathError.insufficientSelection(
                    "This annotation is preserved but cannot be safely edited."
                )
            }
            let contentsChanged = capabilities.contents
                && (annotation.contents ?? "") != payload.contents
            let colorChanged = capabilities.style
                && !colorsMatch(
                    inkColor(
                        from: annotationStyleColor(
                            annotation,
                            type: type
                        )
                    ),
                    requestedColor
                )
            let lineWidthChanged = capabilities.style
                && supportsLineWidth(type)
                && requestedLineWidth.map {
                    abs(
                        effectiveLineWidth(annotation) - $0
                    ) > 0.05
                } == true
            guard contentsChanged || colorChanged || lineWidthChanged else {
                throw PaperPathError.insufficientSelection(
                    "The annotation has no changes to save."
                )
            }
            if contentsChanged {
                annotation.contents = payload.contents
            }
            let visibleTextChanged = contentsChanged
                && type.caseInsensitiveCompare("FreeText")
                    == .orderedSame
            if colorChanged || lineWidthChanged || visibleTextChanged {
                annotation.removeValue(
                    forAnnotationKey: .appearanceDictionary
                )
            }
            if colorChanged {
                annotation.color = color
                if type.caseInsensitiveCompare("FreeText")
                    == .orderedSame {
                    annotation.fontColor = color
                }
            }
            if lineWidthChanged, let requestedLineWidth {
                let border = annotation.border ?? PDFBorder()
                border.lineWidth = requestedLineWidth
                annotation.border = border
            }
            annotation.modificationDate = Date()
            if annotation.userName?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty != false {
                annotation.userName = "PaperPath"
            }
        }
    }

    func removeAnnotations(
        _ targets: [PDFAnnotationRemovalTarget],
        in url: URL
    ) throws -> Int {
        guard !targets.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Select at least one removable annotation."
            )
        }
        guard targets.count <= 2_000 else {
            throw PaperPathError.insufficientSelection(
                "Remove up to 2,000 annotations at a time."
            )
        }
        let keys = targets.map {
            "\($0.pageIndex):\($0.annotationIndex)"
        }
        guard Set(keys).count == targets.count,
              targets.allSatisfy({
                $0.pageIndex >= 0 && $0.annotationIndex >= 0
              })
        else {
            throw PaperPathError.insufficientSelection(
                "The annotation selection is no longer valid."
            )
        }
        let groupedTargets = Dictionary(
            grouping: targets,
            by: \.pageIndex
        )
        var expectedSurvivors: [Int: [String]] = [:]

        try mutate(
            url: url,
            verification: { document, _ in
                for (pageIndex, expected) in expectedSurvivors {
                    try Task.checkCancellation()
                    guard let page = document.page(at: pageIndex),
                          page.annotations.map(
                            annotationRemovalSignature
                          ).sorted() == expected
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "the remaining annotations changed during removal"
                        )
                    }
                }
            }
        ) { document in
            for (pageIndex, pageTargets) in groupedTargets {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex)
                else {
                    throw PaperPathError.invalidPage
                }
                for target in pageTargets {
                    guard page.annotations.indices.contains(
                        target.annotationIndex
                    ),
                          annotation(
                            page.annotations[target.annotationIndex],
                            matches: target
                          )
                    else {
                        throw PaperPathError.insufficientSelection(
                            "One or more annotations changed before removal."
                        )
                    }
                }
            }

            for (pageIndex, pageTargets) in groupedTargets {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex)
                else {
                    throw PaperPathError.invalidPage
                }
                let removedIndices = Set(
                    pageTargets.map(\.annotationIndex)
                )
                expectedSurvivors[pageIndex] = page.annotations
                    .enumerated()
                    .filter { !removedIndices.contains($0.offset) }
                    .map { annotationRemovalSignature($0.element) }
                    .sorted()
                for index in removedIndices.sorted(by: >) {
                    page.removeAnnotation(page.annotations[index])
                }
            }
        }
        return targets.count
    }

    private func normalizedAnnotationType(
        _ annotation: PDFAnnotation
    ) -> String {
        annotation.type?
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            ) ?? "Annotation"
    }

    private func annotationCapabilities(
        _ annotation: PDFAnnotation,
        type: String
    ) -> (contents: Bool, style: Bool) {
        let normalized = type.lowercased()
        if normalized == "ink",
           annotation.contents?
            .caseInsensitiveCompare("Signature") == .orderedSame {
            return (false, false)
        }
        let editableContents: Bool
        switch normalized {
        case "highlight", "underline", "strikeout", "ink",
             "text", "square", "circle", "line", "stamp":
            editableContents = true
        case "freetext":
            editableContents = true
        default:
            editableContents = false
        }
        let editableStyle: Bool
        switch normalized {
        case "highlight", "underline", "strikeout", "ink",
             "text", "freetext", "square", "circle", "line":
            editableStyle = true
        default:
            editableStyle = false
        }
        return (editableContents, editableStyle)
    }

    private func annotation(
        _ annotation: PDFAnnotation,
        matches target: PDFAnnotationRemovalTarget
    ) -> Bool {
        guard normalizedAnnotationType(annotation)
                .caseInsensitiveCompare(target.expectedType)
                == .orderedSame
        else { return false }
        if let expectedIdentity = target.expectedMutationIdentity {
            return annotationMutationIdentity(annotation)
                == expectedIdentity
        }
        return annotation.contents == target.expectedContents
            && PDFGeneratedAnnotationKind.resolve(
                author: annotation.userName
            ) == target.expectedGeneratedKind
    }

    private func annotationRemovalSignature(
        _ annotation: PDFAnnotation
    ) -> String {
        annotationMutationIdentity(annotation)
    }

    private func annotationMutationIdentity(
        _ annotation: PDFAnnotation
    ) -> String {
        let bounds = annotation.bounds
        let color = inkColor(
            from: annotationStyleColor(
                annotation,
                type: normalizedAnnotationType(annotation)
            )
        )
        func rounded(_ value: Double) -> String {
            String(format: "%.3f", value)
        }
        let components = [
            normalizedAnnotationType(annotation).lowercased(),
            annotation.contents ?? "",
            annotation.userName ?? "",
            annotation.fieldName ?? "",
            annotation.stampName ?? "",
            rounded(Double(bounds.origin.x)),
            rounded(Double(bounds.origin.y)),
            rounded(Double(bounds.width)),
            rounded(Double(bounds.height)),
            rounded(color.red),
            rounded(color.green),
            rounded(color.blue),
            rounded(color.alpha),
            rounded(effectiveLineWidth(annotation)),
            annotation.url?.absoluteString
                ?? (annotation.action as? PDFActionURL)?
                    .url?.absoluteString
                ?? ""
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(components.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func supportsLineWidth(_ type: String) -> Bool {
        switch type.lowercased() {
        case "ink", "square", "circle", "line":
            return true
        default:
            return false
        }
    }

    private func annotationStyleColor(
        _ annotation: PDFAnnotation,
        type: String
    ) -> UIColor {
        if type.caseInsensitiveCompare("FreeText") == .orderedSame,
           let fontColor = annotation.fontColor {
            return fontColor
        }
        return annotation.color
    }

    private func effectiveLineWidth(
        _ annotation: PDFAnnotation
    ) -> Double {
        Double(annotation.border?.lineWidth ?? 1)
    }

    private func inkColor(from color: UIColor) -> PDFInkColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        if color.getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        ) {
            return PDFInkColor(
                red: red,
                green: green,
                blue: blue,
                alpha: alpha
            )
        }
        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            return PDFInkColor(
                red: white,
                green: white,
                blue: white,
                alpha: alpha
            )
        }
        return PDFInkColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1
        )
    }

    func refreshFormAutomation(in url: URL) throws {
        let report = try PDFFormInspectionService().inspect(url: url)
        guard report.unsupportedJavaScriptCount == 0 else {
            throw PaperPathError.insufficientSelection(
                "Custom form scripts require a compatible PDF reader."
            )
        }
        if let issue = report.invalidAutomationFields
            .compactMap(\.validationIssue)
            .first {
            throw PaperPathError.insufficientSelection(issue)
        }
        let updates = report.calculatedFields.reduce(
            into: [String: String]()
        ) { result, field in
            guard let expected = field.expectedValue else { return }
            result[normalizedFormFieldName(field.fieldName)] = expected
        }
        guard !updates.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "No supported calculated fields were found."
            )
        }
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".mutation-\(UUID().uuidString).pdf"
            )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try PDFOutputService().applyFormFieldValues(
            sourceURL: url,
            destination: temporaryURL,
            values: updates
        )
        try commitReplacement(
            at: url,
            with: temporaryURL
        )
    }

    private func colorsMatch(
        _ left: PDFInkColor,
        _ right: PDFInkColor
    ) -> Bool {
        let tolerance = 0.025
        return abs(left.red - right.red) <= tolerance
            && abs(left.green - right.green) <= tolerance
            && abs(left.blue - right.blue) <= tolerance
    }

    private func isLink(_ annotation: PDFAnnotation) -> Bool {
        let normalizedType = annotation.type?
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        let linkType = PDFAnnotationSubtype.link.rawValue
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        let isLinkSubtype = normalizedType?
            .caseInsensitiveCompare(linkType) == .orderedSame
        return isLinkSubtype
            || annotation.url != nil
            || annotation.destination != nil
            || annotation.action is PDFActionURL
            || annotation.action is PDFActionGoTo
    }

    private func linkTarget(
        _ annotation: PDFAnnotation,
        document: PDFDocument
    ) -> PDFLinkTarget {
        if let url = annotation.url
            ?? (annotation.action as? PDFActionURL)?.url {
            return Self.isSupportedWebURL(url)
                ? .web(url)
                : .unsupported("Unsupported URL action")
        }
        let destination = annotation.destination
            ?? (annotation.action as? PDFActionGoTo)?.destination
        if let page = destination?.page {
            let index = document.index(for: page)
            if index != NSNotFound {
                return .page(index)
            }
        }
        if let action = annotation.action {
            return .unsupported(
                "Unsupported \(String(describing: type(of: action))) action"
            )
        }
        return .unsupported("Missing link target")
    }

    private static func isSupportedWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              host.utf8.count <= 253,
              url.user == nil,
              url.password == nil,
              url.absoluteString.utf8.count <= 4_096
        else { return false }
        return url.absoluteString.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
        }
    }

    private func normalizedFormFieldName(
        _ value: String
    ) -> String {
        value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func paperClass(
        for size: CGSize
    ) -> PDFPagePaperClass {
        let shortEdge = min(size.width, size.height)
        let longEdge = max(size.width, size.height)
        let tolerance = 0.035

        func matches(
            short expectedShort: CGFloat,
            long expectedLong: CGFloat
        ) -> Bool {
            abs(shortEdge - expectedShort) / expectedShort <= tolerance
                && abs(longEdge - expectedLong) / expectedLong <= tolerance
        }

        if matches(short: 595, long: 842) {
            return .a4
        }
        if matches(short: 612, long: 792) {
            return .letter
        }
        if matches(short: 612, long: 1_008) {
            return .legal
        }
        if abs(size.width - size.height)
            / max(size.width, size.height) <= 0.05 {
            return .square
        }
        return .custom
    }

    private func detectedContentBounds(
        in image: UIImage
    ) -> (
        insets: PDFPageCropInsets,
        confidence: PDFPageCropConfidence,
        inkCoverage: Double
    ) {
        guard let cgImage = image.cgImage else {
            return (.none, .low, 0)
        }
        let width = min(max(cgImage.width, 1), 640)
        let height = min(max(cgImage.height, 1), 640)
        let bytesPerRow = width * 4
        var pixels = [UInt8](
            repeating: 255,
            count: bytesPerRow * height
        )
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.setFillColor(UIColor.white.cgColor)
            context.fill(
                CGRect(x: 0, y: 0, width: width, height: height)
            )
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else {
            return (.none, .low, 0)
        }

        func luminance(x: Int, y: Int) -> Int {
            let offset = y * bytesPerRow + x * 4
            return (
                54 * Int(pixels[offset])
                    + 183 * Int(pixels[offset + 1])
                    + 19 * Int(pixels[offset + 2])
            ) / 256
        }

        let sampleInsetX = max(1, width / 50)
        let sampleInsetY = max(1, height / 50)
        let backgroundSamples = [
            luminance(x: sampleInsetX, y: sampleInsetY),
            luminance(
                x: width - sampleInsetX - 1,
                y: sampleInsetY
            ),
            luminance(
                x: sampleInsetX,
                y: height - sampleInsetY - 1
            ),
            luminance(
                x: width - sampleInsetX - 1,
                y: height - sampleInsetY - 1
            )
        ].sorted()
        let background = (
            backgroundSamples[1] + backgroundSamples[2]
        ) / 2
        var rowCounts = [Int](repeating: 0, count: height)
        var columnCounts = [Int](repeating: 0, count: width)
        var inkPixelCount = 0
        let scanInsetX = max(1, width / 160)
        let scanInsetY = max(1, height / 160)
        for y in scanInsetY..<(height - scanInsetY) {
            if y.isMultiple(of: 32), Task.isCancelled {
                return (.none, .low, 0)
            }
            for x in scanInsetX..<(width - scanInsetX) {
                let value = luminance(x: x, y: y)
                let differsFromPaper = abs(value - background) >= 20
                let visibleOnWhite = background >= 238 && value <= 232
                guard differsFromPaper || visibleOnWhite else {
                    continue
                }
                rowCounts[y] += 1
                columnCounts[x] += 1
                inkPixelCount += 1
            }
        }

        let rowThreshold = max(2, width / 220)
        let columnThreshold = max(2, height / 220)
        guard let firstRow = rowCounts.firstIndex(where: {
            $0 >= rowThreshold
        }),
        let lastRow = rowCounts.lastIndex(where: {
            $0 >= rowThreshold
        }),
        let firstColumn = columnCounts.firstIndex(where: {
            $0 >= columnThreshold
        }),
        let lastColumn = columnCounts.lastIndex(where: {
            $0 >= columnThreshold
        })
        else {
            return (.none, .low, 0)
        }

        let insets = PDFPageCropInsets(
            top: min(0.4, Double(firstRow) / Double(height)),
            right: min(
                0.4,
                Double(width - lastColumn - 1) / Double(width)
            ),
            bottom: min(
                0.4,
                Double(height - lastRow - 1) / Double(height)
            ),
            left: min(0.4, Double(firstColumn) / Double(width))
        ).clamped
        let coverage = Double(inkPixelCount)
            / Double(max(1, width * height))
        let confidence: PDFPageCropConfidence
        if coverage >= 0.004,
           insets.totalInset >= 0.14 {
            confidence = .high
        } else if coverage >= 0.0015,
                  insets.totalInset >= 0.055 {
            confidence = .medium
        } else {
            confidence = .low
        }
        return (insets, confidence, coverage)
    }

    private func isGeneratedPageNumber(
        _ annotation: PDFAnnotation
    ) -> Bool {
        annotation.userName
            == PDFGeneratedAnnotationKind.pageNumber.author
    }

    private func isGeneratedWatermark(
        _ annotation: PDFAnnotation
    ) -> Bool {
        annotation.userName
            == PDFGeneratedAnnotationKind.watermark.author
    }

    private func isGeneratedBatesNumber(
        _ annotation: PDFAnnotation
    ) -> Bool {
        annotation.userName
            == PDFGeneratedAnnotationKind.batesNumber.author
    }

    private func normalizedWatermarkText(
        _ value: String
    ) throws -> String {
        guard value.rangeOfCharacter(
            from: .controlCharacters
        ) == nil else {
            throw PaperPathError.insufficientSelection(
                "Use a single line of watermark text."
            )
        }
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty, normalized.count <= 64 else {
            throw PaperPathError.insufficientSelection(
                "Use 1 to 64 characters for the watermark."
            )
        }
        return normalized
    }

    private func annotationRotation(
        _ annotation: PDFAnnotation
    ) -> Int {
        (
            annotation.value(
                forAnnotationKey: PDFAnnotationKey(
                    rawValue: "Rotate"
                )
            ) as? NSNumber
        )?.intValue ?? 0
    }

    private func annotationOpacity(
        _ annotation: PDFAnnotation
    ) -> Double {
        (
            annotation.value(
                forAnnotationKey: PDFAnnotationKey(
                    rawValue: "PaperPathOpacity"
                )
            ) as? NSNumber
        )?.doubleValue ?? 1
    }

    private func watermarkBounds(
        layout: PDFWatermarkLayout,
        intensity: PDFWatermarkIntensity,
        pageBounds: CGRect
    ) -> CGRect {
        let minimumDimension = min(
            pageBounds.width,
            pageBounds.height
        )
        let margin = min(36, max(12, minimumDimension * 0.04))
        let availableWidth = max(24, pageBounds.width - margin * 2)
        let horizontalHeight = min(
            max(20, minimumDimension * 0.055),
            36
        )
        let centeredHeight = min(
            max(
                44,
                minimumDimension * 0.16
                    * CGFloat(intensity.scale)
            ),
            max(44, pageBounds.height * 0.28)
        )
        let height: CGFloat
        let y: CGFloat
        switch layout {
        case .diagonal, .centered:
            height = centeredHeight
            y = pageBounds.midY - height / 2
        case .header:
            height = horizontalHeight
            y = pageBounds.maxY - margin - height
        case .footer:
            height = horizontalHeight
            y = pageBounds.minY + margin
        }
        return CGRect(
            x: pageBounds.minX + margin,
            y: y,
            width: availableWidth,
            height: height
        ).intersection(pageBounds)
    }

    private func watermarkFontSize(
        layout: PDFWatermarkLayout,
        intensity: PDFWatermarkIntensity,
        pageBounds: CGRect,
        textLength: Int
    ) -> CGFloat {
        let minimumDimension = min(
            pageBounds.width,
            pageBounds.height
        )
        let base: CGFloat
        switch layout {
        case .diagonal, .centered:
            base = min(58, max(22, minimumDimension * 0.095))
        case .header, .footer:
            base = min(18, max(10, minimumDimension * 0.026))
        }
        let lengthScale = min(
            1,
            max(0.48, 22 / CGFloat(max(1, textLength)))
        )
        return max(
            9,
            base * CGFloat(intensity.scale) * lengthScale
        )
    }

    private func watermarkColor(
        _ tone: PDFWatermarkTone,
        opacity: Double
    ) -> UIColor {
        let components: (red: Double, green: Double, blue: Double)
        switch tone {
        case .red:
            components = (0.74, 0.08, 0.12)
        case .graphite:
            components = (0.14, 0.16, 0.19)
        case .blue:
            components = (0.05, 0.3, 0.68)
        }
        let clampedOpacity = min(1, max(0, opacity))
        return UIColor(
            red: 1 - (1 - components.red) * clampedOpacity,
            green: 1 - (1 - components.green) * clampedOpacity,
            blue: 1 - (1 - components.blue) * clampedOpacity,
            alpha: 1
        )
    }

    private func pageNumberBounds(
        position: PDFPageNumberPosition,
        pageBounds: CGRect,
        text: String
    ) -> CGRect {
        let minimumDimension = min(
            pageBounds.width,
            pageBounds.height
        )
        let margin = min(32, max(12, minimumDimension * 0.035))
        let height = min(26, max(18, pageBounds.height * 0.03))
        let estimatedWidth = CGFloat(max(1, text.count)) * 7.2 + 16
        let width = min(
            max(48, estimatedWidth),
            max(48, pageBounds.width - margin * 2)
        )

        let x: CGFloat
        switch position {
        case .topLeft, .bottomLeft:
            x = pageBounds.minX + margin
        case .topCenter, .bottomCenter:
            x = pageBounds.midX - width / 2
        case .topRight, .bottomRight:
            x = pageBounds.maxX - margin - width
        }

        let y: CGFloat
        switch position {
        case .topLeft, .topCenter, .topRight:
            y = pageBounds.maxY - margin - height
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = pageBounds.minY + margin
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func batesFontSize(
        text: String,
        bounds: CGRect,
        pageBounds: CGRect
    ) -> CGFloat? {
        let preferred = min(
            11,
            max(8, pageBounds.height * 0.014)
        )
        let availableWidth = max(1, bounds.width - 8)
        let estimatedWidth = CGFloat(max(1, text.count))
            * preferred * 0.62
        let fitted = preferred * min(
            1,
            availableWidth / estimatedWidth
        )
        guard fitted >= 6 else { return nil }
        return fitted
    }

    private func textAlignment(
        for position: PDFPageNumberPosition
    ) -> NSTextAlignment {
        switch position {
        case .topLeft, .bottomLeft:
            return .left
        case .topCenter, .bottomCenter:
            return .center
        case .topRight, .bottomRight:
            return .right
        }
    }

    private static func validateInkPayload(
        _ payload: PDFInkPayload
    ) throws {
        guard payload.pageIndex >= 0,
              !payload.strokes.isEmpty,
              payload.strokes.count <= PDFInkPayload.maximumStrokeCount
        else {
            throw PaperPathError.insufficientSelection(
                "Draw between 1 and 400 strokes."
            )
        }
        if payload.placement == .signature,
           let bounds = payload.normalizedBounds,
           !isValidNormalizedRect(bounds) {
            throw PaperPathError.insufficientSelection(
                "Keep the signature area fully inside the page."
            )
        }

        var totalPointCount = 0
        for (index, stroke) in payload.strokes.enumerated() {
            if index.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            let (nextPointCount, overflow) = totalPointCount
                .addingReportingOverflow(stroke.points.count)
            guard (2...PDFInkPayload.maximumPointsPerStroke)
                    .contains(stroke.points.count),
                  !overflow,
                  nextPointCount <= PDFInkPayload.maximumTotalPointCount,
                  stroke.points.allSatisfy({
                      $0.x.isFinite
                          && $0.y.isFinite
                          && (0...1).contains($0.x)
                          && (0...1).contains($0.y)
                  }),
                  stroke.normalizedLineWidth.map({
                      $0.isFinite && (0.0005...0.08).contains($0)
                  }) ?? true,
                  stroke.color.map(isValidInkColor) ?? true
            else {
                throw PaperPathError.insufficientSelection(
                    "The drawing exceeds the safe stroke or point limit."
                )
            }
            totalPointCount = nextPointCount
        }
    }

    private static func isValidInkColor(_ color: PDFInkColor) -> Bool {
        [
            color.red,
            color.green,
            color.blue,
            color.alpha
        ].allSatisfy {
            $0.isFinite && (0...1).contains($0)
        }
    }

    private static func isSafeSingleLineText(
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

    private static func isSafeEditableText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                (0x202A...0x202E).contains(codePoint)
                    || (0x2066...0x2069).contains(codePoint)
            let isAllowedWhitespace = scalar == "\n" || scalar == "\t"
            return !CharacterSet.illegalCharacters.contains(scalar)
                && (!CharacterSet.controlCharacters.contains(scalar)
                    || isAllowedWhitespace)
                && !isBidirectionalControl
        }
    }

    private static func isValidNormalizedRect(
        _ bounds: PDFNormalizedRect
    ) -> Bool {
        let values = [
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height
        ]
        return values.allSatisfy(\.isFinite)
            && bounds.x >= 0
            && bounds.y >= 0
            && bounds.width >= 0.01
            && bounds.height >= 0.01
            && bounds.x + bounds.width <= 1.001
            && bounds.y + bounds.height <= 1.001
    }

    private static func hasValidPageBounds(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width > 0
            && bounds.height > 0
    }

    private static func requireSupportedPageCount(
        _ pageCount: Int
    ) throws {
        guard (1...Self.maximumPageCount).contains(pageCount) else {
            throw PaperPathError.insufficientSelection(
                "Process PDFs with up to 100,000 pages at a time."
            )
        }
    }

    private static func requireBoundedSelection(
        _ indices: [Int]
    ) throws {
        guard indices.count <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Select up to 100,000 pages at a time."
            )
        }
    }

    private func mutate(
        url: URL,
        verification: ((PDFDocument, URL) throws -> Void)? = nil,
        operation: (PDFDocument) throws -> Void
    ) throws {
        guard let document = PDFDocument(url: url) else {
            throw PaperPathError.unreadablePDF
        }
        guard !document.isLocked else {
            throw PaperPathError.lockedPDF
        }
        try Self.requireSupportedPageCount(document.pageCount)
        try Task.checkCancellation()

        try operation(document)
        try Self.requireSupportedPageCount(document.pageCount)
        let expectedPageCount = document.pageCount
        try Task.checkCancellation()
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".mutation-\(UUID().uuidString).pdf"
            )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            guard document.write(to: temporaryURL) else {
                throw PaperPathError.storageFailure(
                    "The changed PDF could not be encoded."
                )
            }
            try LocalFileSecurity.requireCompleteProtection(
                to: temporaryURL
            )
            guard let reopened = PDFDocument(url: temporaryURL),
                  !reopened.isLocked,
                  reopened.pageCount == expectedPageCount
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the changed PDF could not be reopened with every page"
                )
            }
            if let verification {
                try verification(reopened, temporaryURL)
            }
            try Task.checkCancellation()
            try commitReplacement(
                at: url,
                with: temporaryURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PaperPathError {
            throw error
        } catch {
            throw PaperPathError.storageFailure("The changed PDF could not be written.")
        }
    }

    private func commitReplacement(
        at destinationURL: URL,
        with stagingURL: URL
    ) throws {
        let fileManager = FileManager.default
        let backupName = ".mutation-rollback-\(UUID().uuidString).pdf"
        let backupURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(backupName)
        defer {
            try? fileManager.removeItem(at: backupURL)
        }

        var replacementStarted = false
        do {
            replacementStarted = true
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: backupName,
                options: [.withoutDeletingBackupItem]
            )
            if fileManager.fileExists(atPath: backupURL.path) {
                try LocalFileSecurity.requireCompleteProtection(
                    to: backupURL
                )
            }
            try LocalFileSecurity.requireCompleteProtection(
                to: destinationURL
            )
        } catch {
            guard replacementStarted,
                  fileManager.fileExists(atPath: backupURL.path)
            else {
                throw error
            }
            do {
                let rollbackFingerprint = try fileFingerprint(
                    at: backupURL
                )
                if fileManager.fileExists(atPath: destinationURL.path) {
                    _ = try fileManager.replaceItemAt(
                        destinationURL,
                        withItemAt: backupURL
                    )
                } else {
                    try fileManager.moveItem(
                        at: backupURL,
                        to: destinationURL
                    )
                }
                try LocalFileSecurity.requireCompleteProtection(
                    to: destinationURL
                )
                guard try fileFingerprint(at: destinationURL)
                        == rollbackFingerprint
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the original PDF did not match its rollback copy"
                    )
                }
            } catch {
                throw PaperPathError.storageFailure(
                    "The PDF changed, but its rollback copy could not be restored."
                )
            }
            throw error
        }
    }

    private func fileFingerprint(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576)
                ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func stampColor(for kind: PDFStampKind) -> UIColor {
        switch kind {
        case .approved:
            return .systemGreen
        case .draft:
            return .systemOrange
        case .confidential, .void:
            return .systemRed
        case .final:
            return .systemBlue
        }
    }
}
