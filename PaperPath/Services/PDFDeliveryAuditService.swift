import CryptoKit
import Foundation
import PDFKit
import UIKit
@preconcurrency import Vision

struct PDFVectorFragment {
    let fingerprint: Data
    let region: PDFDifferenceRegion
}

private struct PDFVectorGraphicsState {
    var transform = CGAffineTransform.identity
    var lineWidth: CGFloat = 1
    var strokeStyle = "gray:0"
    var fillStyle = "gray:0"
}

private final class PDFVectorScanBudget {
    let maximumOperations: Int
    let maximumFragments: Int
    var operationCount = 0
    var fragmentCount = 0
    var isIncomplete = false

    init(
        maximumOperations: Int,
        maximumFragments: Int
    ) {
        self.maximumOperations = maximumOperations
        self.maximumFragments = maximumFragments
    }

    func consumeOperation() -> Bool {
        guard !isIncomplete else { return false }
        guard !Task.isCancelled else {
            isIncomplete = true
            return false
        }
        operationCount += 1
        guard operationCount <= maximumOperations else {
            isIncomplete = true
            return false
        }
        return true
    }

    func consumeFragment() -> Bool {
        guard !isIncomplete,
              fragmentCount < maximumFragments
        else {
            isIncomplete = true
            return false
        }
        fragmentCount += 1
        return true
    }
}

private final class PDFVectorScanState {
    let pageBounds: CGRect
    let resources: CGPDFDictionaryRef?
    let contentStream: CGPDFContentStreamRef
    let depth: Int
    let budget: PDFVectorScanBudget
    var graphicsState: PDFVectorGraphicsState
    var graphicsStack: [PDFVectorGraphicsState] = []
    var pathBounds: CGRect?
    var pathTokens: [String] = []
    var pathIsIncomplete = false
    var fragments: [PDFVectorFragment] = []

    init(
        pageBounds: CGRect,
        resources: CGPDFDictionaryRef?,
        contentStream: CGPDFContentStreamRef,
        depth: Int = 0,
        budget: PDFVectorScanBudget,
        graphicsState: PDFVectorGraphicsState =
            PDFVectorGraphicsState()
    ) {
        self.pageBounds = pageBounds
        self.resources = resources
        self.contentStream = contentStream
        self.depth = depth
        self.budget = budget
        self.graphicsState = graphicsState
    }

    func addPoint(
        _ point: CGPoint,
        operation: String
    ) {
        guard point.x.isFinite,
              point.y.isFinite
        else {
            pathIsIncomplete = true
            return
        }
        let transformed = point.applying(graphicsState.transform)
        guard transformed.x.isFinite,
              transformed.y.isFinite
        else {
            pathIsIncomplete = true
            return
        }
        let pointBounds = CGRect(
            x: transformed.x,
            y: transformed.y,
            width: 0,
            height: 0
        )
        pathBounds = pathBounds.map {
            $0.union(pointBounds)
        } ?? pointBounds
        addToken(
            "\(operation):\(pdfVectorQuantized(transformed.x)),\(pdfVectorQuantized(transformed.y))"
        )
    }

    func addRectangle(_ rectangle: CGRect) {
        guard rectangle.origin.x.isFinite,
              rectangle.origin.y.isFinite,
              rectangle.width.isFinite,
              rectangle.height.isFinite
        else {
            pathIsIncomplete = true
            return
        }
        let corners = [
            CGPoint(x: rectangle.minX, y: rectangle.minY),
            CGPoint(x: rectangle.maxX, y: rectangle.minY),
            CGPoint(x: rectangle.maxX, y: rectangle.maxY),
            CGPoint(x: rectangle.minX, y: rectangle.maxY)
        ]
        for corner in corners {
            addPoint(corner, operation: "re")
        }
    }

    func addToken(_ token: String) {
        guard pathTokens.count < 192 else {
            pathIsIncomplete = true
            return
        }
        pathTokens.append(token)
    }

    func clearPath() {
        pathBounds = nil
        pathTokens.removeAll(keepingCapacity: true)
        pathIsIncomplete = false
    }

    func paint(
        operation: String,
        strokes: Bool,
        fills: Bool,
        closesPath: Bool = false
    ) {
        if closesPath {
            addToken("h")
        }
        defer { clearPath() }
        guard !pathIsIncomplete,
              let pathBounds,
              !pathTokens.isEmpty
        else { return }

        var paintedBounds = pathBounds.standardized
        if strokes {
            let xScale = hypot(
                graphicsState.transform.a,
                graphicsState.transform.b
            )
            let yScale = hypot(
                graphicsState.transform.c,
                graphicsState.transform.d
            )
            let expansion = max(
                0.5,
                graphicsState.lineWidth * max(xScale, yScale) / 2
            )
            paintedBounds = paintedBounds.insetBy(
                dx: -expansion,
                dy: -expansion
            )
        }
        paintedBounds = paintedBounds.intersection(pageBounds)
        guard !paintedBounds.isNull,
              paintedBounds.width > 0.25,
              paintedBounds.height > 0.25,
              pageBounds.width > 0,
              pageBounds.height > 0,
              budget.consumeFragment()
        else { return }

        var material = pathTokens.joined(separator: "|")
        material += "|paint:\(operation)"
        if strokes {
            material += "|stroke:\(graphicsState.strokeStyle)"
            material += "|width:\(pdfVectorQuantized(graphicsState.lineWidth))"
        }
        if fills {
            material += "|fill:\(graphicsState.fillStyle)"
        }
        fragments.append(
            PDFVectorFragment(
                fingerprint: Data(
                    SHA256.hash(data: Data(material.utf8))
                ),
                region: PDFDifferenceRegion(
                    x: Double(
                        (paintedBounds.minX - pageBounds.minX)
                            / pageBounds.width
                    ),
                    y: Double(
                        (pageBounds.maxY - paintedBounds.maxY)
                            / pageBounds.height
                    ),
                    width: Double(
                        paintedBounds.width / pageBounds.width
                    ),
                    height: Double(
                        paintedBounds.height / pageBounds.height
                    ),
                    intensity: 1
                )
            )
        )
    }

    func merge(_ child: PDFVectorScanState) {
        fragments.append(contentsOf: child.fragments)
    }
}

private func pdfVectorQuantized(_ value: CGFloat) -> String {
    guard value.isFinite else { return "invalid" }
    let bounded = min(10_000_000, max(-10_000_000, value))
    return String(Int((bounded * 100).rounded()))
}

private func pdfVectorState(
    _ info: UnsafeMutableRawPointer?
) -> PDFVectorScanState? {
    guard let info else { return nil }
    return Unmanaged<PDFVectorScanState>
        .fromOpaque(info)
        .takeUnretainedValue()
}

private func pdfVectorConsumeOperation(
    _ scanner: CGPDFScannerRef,
    info: UnsafeMutableRawPointer?
) -> PDFVectorScanState? {
    guard let state = pdfVectorState(info) else {
        CGPDFScannerStop(scanner)
        return nil
    }
    guard state.budget.consumeOperation() else {
        CGPDFScannerStop(scanner)
        return nil
    }
    return state
}

private func pdfVectorPopPoint(
    _ scanner: CGPDFScannerRef
) -> CGPoint? {
    var y: CGPDFReal = 0
    var x: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &y),
          CGPDFScannerPopNumber(scanner, &x)
    else { return nil }
    return CGPoint(x: x, y: y)
}

private func pdfVectorPopValues(
    _ scanner: CGPDFScannerRef,
    count: Int
) -> [CGFloat]? {
    guard count > 0 else { return [] }
    var reversed: [CGFloat] = []
    reversed.reserveCapacity(count)
    for _ in 0..<count {
        var value: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &value) else {
            return nil
        }
        reversed.append(value)
    }
    return Array(reversed.reversed())
}

private func pdfVectorStyle(
    _ values: [CGFloat],
    prefix: String
) -> String {
    "\(prefix):\(values.map(pdfVectorQuantized).joined(separator: ","))"
}

private let pdfVectorPushGraphicsState: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ) else { return }
    state.graphicsStack.append(state.graphicsState)
}

private let pdfVectorPopGraphicsState: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ) else { return }
    if let previous = state.graphicsStack.popLast() {
        state.graphicsState = previous
    }
}

private let pdfVectorConcatenateMatrix: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ),
          let values = pdfVectorPopValues(scanner, count: 6)
    else { return }
    let matrix = CGAffineTransform(
        a: values[0],
        b: values[1],
        c: values[2],
        d: values[3],
        tx: values[4],
        ty: values[5]
    )
    state.graphicsState.transform = matrix.concatenating(
        state.graphicsState.transform
    )
}

private let pdfVectorSetLineWidth: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ),
          let values = pdfVectorPopValues(scanner, count: 1),
          let width = values.first,
          width.isFinite
    else { return }
    state.graphicsState.lineWidth = max(0, width)
}

private let pdfVectorMoveTo: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ),
          let point = pdfVectorPopPoint(scanner)
    else { return }
    state.addPoint(point, operation: "m")
}

private let pdfVectorLineTo: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ),
          let point = pdfVectorPopPoint(scanner)
    else { return }
    state.addPoint(point, operation: "l")
}

private let pdfVectorCurveTo: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ),
          let values = pdfVectorPopValues(scanner, count: 6)
    else { return }
    state.addPoint(
        CGPoint(x: values[0], y: values[1]),
        operation: "c1"
    )
    state.addPoint(
        CGPoint(x: values[2], y: values[3]),
        operation: "c2"
    )
    state.addPoint(
        CGPoint(x: values[4], y: values[5]),
        operation: "c3"
    )
}

private let pdfVectorCurveToV: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ),
          let values = pdfVectorPopValues(scanner, count: 4)
    else { return }
    state.addPoint(
        CGPoint(x: values[0], y: values[1]),
        operation: "v1"
    )
    state.addPoint(
        CGPoint(x: values[2], y: values[3]),
        operation: "v2"
    )
}

private let pdfVectorCurveToY: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ),
          let values = pdfVectorPopValues(scanner, count: 4)
    else { return }
    state.addPoint(
        CGPoint(x: values[0], y: values[1]),
        operation: "y1"
    )
    state.addPoint(
        CGPoint(x: values[2], y: values[3]),
        operation: "y2"
    )
}

private let pdfVectorRectangle: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ),
          let values = pdfVectorPopValues(scanner, count: 4)
    else { return }
    state.addRectangle(
        CGRect(
            x: values[0],
            y: values[1],
            width: values[2],
            height: values[3]
        )
    )
}

private let pdfVectorClosePath: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ) else { return }
    state.addToken("h")
}

private let pdfVectorEndPath: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ) else { return }
    state.clearPath()
}

private func pdfVectorPaint(
    _ scanner: CGPDFScannerRef,
    _ info: UnsafeMutableRawPointer?,
    operation: String,
    strokes: Bool,
    fills: Bool,
    closesPath: Bool = false
) {
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ) else { return }
    state.paint(
        operation: operation,
        strokes: strokes,
        fills: fills,
        closesPath: closesPath
    )
    if state.budget.isIncomplete {
        CGPDFScannerStop(scanner)
    }
}

private let pdfVectorStroke: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorPaint(
        scanner,
        info,
        operation: "S",
        strokes: true,
        fills: false
    )
}

private let pdfVectorCloseStroke: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorPaint(
        scanner,
        info,
        operation: "s",
        strokes: true,
        fills: false,
        closesPath: true
    )
}

private let pdfVectorFill: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorPaint(
        scanner,
        info,
        operation: "f",
        strokes: false,
        fills: true
    )
}

private let pdfVectorEvenOddFill: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorPaint(
        scanner,
        info,
        operation: "f*",
        strokes: false,
        fills: true
    )
}

private let pdfVectorFillStroke: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorPaint(
        scanner,
        info,
        operation: "B",
        strokes: true,
        fills: true
    )
}

private let pdfVectorEvenOddFillStroke: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorPaint(
        scanner,
        info,
        operation: "B*",
        strokes: true,
        fills: true
    )
}

private let pdfVectorCloseFillStroke: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorPaint(
        scanner,
        info,
        operation: "b",
        strokes: true,
        fills: true,
        closesPath: true
    )
}

private let pdfVectorCloseEvenOddFillStroke: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorPaint(
        scanner,
        info,
        operation: "b*",
        strokes: true,
        fills: true,
        closesPath: true
    )
}

private func pdfVectorSetColor(
    scanner: CGPDFScannerRef,
    info: UnsafeMutableRawPointer?,
    componentCount: Int,
    prefix: String,
    stroke: Bool
) {
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ),
          let values = pdfVectorPopValues(
              scanner,
              count: componentCount
          ),
          values.allSatisfy(\.isFinite)
    else { return }
    let style = pdfVectorStyle(values, prefix: prefix)
    if stroke {
        state.graphicsState.strokeStyle = style
    } else {
        state.graphicsState.fillStyle = style
    }
}

private let pdfVectorSetStrokeGray: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorSetColor(
        scanner: scanner,
        info: info,
        componentCount: 1,
        prefix: "gray",
        stroke: true
    )
}

private let pdfVectorSetFillGray: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorSetColor(
        scanner: scanner,
        info: info,
        componentCount: 1,
        prefix: "gray",
        stroke: false
    )
}

private let pdfVectorSetStrokeRGB: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorSetColor(
        scanner: scanner,
        info: info,
        componentCount: 3,
        prefix: "rgb",
        stroke: true
    )
}

private let pdfVectorSetFillRGB: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorSetColor(
        scanner: scanner,
        info: info,
        componentCount: 3,
        prefix: "rgb",
        stroke: false
    )
}

private let pdfVectorSetStrokeCMYK: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorSetColor(
        scanner: scanner,
        info: info,
        componentCount: 4,
        prefix: "cmyk",
        stroke: true
    )
}

private let pdfVectorSetFillCMYK: CGPDFOperatorCallback = {
    scanner, info in
    pdfVectorSetColor(
        scanner: scanner,
        info: info,
        componentCount: 4,
        prefix: "cmyk",
        stroke: false
    )
}

private func pdfVectorFormMatrix(
    _ dictionary: CGPDFDictionaryRef
) -> CGAffineTransform {
    var array: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array),
          let array,
          CGPDFArrayGetCount(array) == 6
    else { return .identity }
    var values = Array(repeating: CGPDFReal(0), count: 6)
    for index in values.indices {
        guard CGPDFArrayGetNumber(array, index, &values[index]) else {
            return .identity
        }
    }
    return CGAffineTransform(
        a: values[0],
        b: values[1],
        c: values[2],
        d: values[3],
        tx: values[4],
        ty: values[5]
    )
}

private let pdfVectorDrawXObject: CGPDFOperatorCallback = {
    scanner, info in
    guard let state = pdfVectorConsumeOperation(
        scanner,
        info: info
    ) else { return }
    var namePointer: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &namePointer),
          let namePointer,
          let resources = state.resources
    else { return }
    var xObjects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(
        resources,
        "XObject",
        &xObjects
    ),
          let xObjects
    else { return }
    var stream: CGPDFStreamRef?
    guard CGPDFDictionaryGetStream(
        xObjects,
        namePointer,
        &stream
    ),
          let stream,
          let dictionary = CGPDFStreamGetDictionary(stream)
    else { return }
    var subtypePointer: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(
        dictionary,
        "Subtype",
        &subtypePointer
    ),
          let subtypePointer,
          String(cString: subtypePointer) == "Form"
    else { return }
    guard state.depth < 4 else {
        state.budget.isIncomplete = true
        return
    }
    var formResources: CGPDFDictionaryRef?
    if !CGPDFDictionaryGetDictionary(
        dictionary,
        "Resources",
        &formResources
    ) {
        formResources = resources
    }
    guard let formResources else {
        state.budget.isIncomplete = true
        return
    }
    let content = CGPDFContentStreamCreateWithStream(
        stream,
        formResources,
        state.contentStream
    )
    defer { CGPDFContentStreamRelease(content) }
    var graphicsState = state.graphicsState
    graphicsState.transform = pdfVectorFormMatrix(dictionary)
        .concatenating(graphicsState.transform)
    let child = PDFVectorScanState(
        pageBounds: state.pageBounds,
        resources: formResources,
        contentStream: content,
        depth: state.depth + 1,
        budget: state.budget,
        graphicsState: graphicsState
    )
    guard pdfScanVectorContent(child) else {
        state.budget.isIncomplete = true
        return
    }
    state.merge(child)
}

private func pdfScanVectorContent(
    _ state: PDFVectorScanState
) -> Bool {
    guard let table = CGPDFOperatorTableCreate() else {
        return false
    }
    defer { CGPDFOperatorTableRelease(table) }
    let callbacks: [(String, CGPDFOperatorCallback)] = [
        ("q", pdfVectorPushGraphicsState),
        ("Q", pdfVectorPopGraphicsState),
        ("cm", pdfVectorConcatenateMatrix),
        ("w", pdfVectorSetLineWidth),
        ("m", pdfVectorMoveTo),
        ("l", pdfVectorLineTo),
        ("c", pdfVectorCurveTo),
        ("v", pdfVectorCurveToV),
        ("y", pdfVectorCurveToY),
        ("re", pdfVectorRectangle),
        ("h", pdfVectorClosePath),
        ("n", pdfVectorEndPath),
        ("S", pdfVectorStroke),
        ("s", pdfVectorCloseStroke),
        ("f", pdfVectorFill),
        ("F", pdfVectorFill),
        ("f*", pdfVectorEvenOddFill),
        ("B", pdfVectorFillStroke),
        ("B*", pdfVectorEvenOddFillStroke),
        ("b", pdfVectorCloseFillStroke),
        ("b*", pdfVectorCloseEvenOddFillStroke),
        ("G", pdfVectorSetStrokeGray),
        ("g", pdfVectorSetFillGray),
        ("RG", pdfVectorSetStrokeRGB),
        ("rg", pdfVectorSetFillRGB),
        ("K", pdfVectorSetStrokeCMYK),
        ("k", pdfVectorSetFillCMYK),
        ("Do", pdfVectorDrawXObject)
    ]
    for callback in callbacks {
        callback.0.withCString {
            CGPDFOperatorTableSetCallback(
                table,
                $0,
                callback.1
            )
        }
    }
    let scanner = CGPDFScannerCreate(
        state.contentStream,
        table,
        Unmanaged.passUnretained(state).toOpaque()
    )
    defer { CGPDFScannerRelease(scanner) }
    return CGPDFScannerScan(scanner)
}

private func pdfVectorFragments(
    in page: CGPDFPage,
    pageBounds: CGRect,
    maximumFragments: Int
) -> [PDFVectorFragment]? {
    guard maximumFragments > 0,
          pageBounds.width > 0,
          pageBounds.height > 0
    else { return nil }
    let content = CGPDFContentStreamCreateWithPage(page)
    defer { CGPDFContentStreamRelease(content) }
    let budget = PDFVectorScanBudget(
        maximumOperations: max(4_096, maximumFragments * 64),
        maximumFragments: maximumFragments
    )
    let state = PDFVectorScanState(
        pageBounds: pageBounds,
        resources: page.dictionary.flatMap { dictionary in
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(
                dictionary,
                "Resources",
                &resources
            ) else { return nil }
            return resources
        },
        contentStream: content,
        budget: budget
    )
    guard pdfScanVectorContent(state),
          !budget.isIncomplete,
          !Task.isCancelled
    else { return nil }
    return state.fragments
}

func pdfOfficeTableRulings(in page: PDFPage) -> [CGRect]? {
    let bounds = page.bounds(for: .cropBox)
    guard let reference = page.pageRef,
          let fragments = pdfVectorFragments(
            in: reference, pageBounds: bounds, maximumFragments: 8_192
          )
    else { return nil }
    return fragments.compactMap { fragment in
        let region = fragment.region
        let rect = CGRect(
            x: bounds.minX + CGFloat(region.x) * bounds.width,
            y: bounds.maxY - CGFloat(region.y + region.height) * bounds.height,
            width: CGFloat(region.width) * bounds.width,
            height: CGFloat(region.height) * bounds.height
        )
        return (rect.width <= 3 && rect.height >= 10)
            || (rect.height <= 3 && rect.width >= 10) ? rect : nil
    }
}

struct PDFDeliveryAuditService: @unchecked Sendable {
    private static let maximumPageCount = 100_000
    private static let maximumFileBytes: Int64 =
        1_024 * 1_024 * 1_024
    private static let maximumCharacterDifferenceMatrixCells = 4_096
    private static let maximumLocatedTextEvidencePerSide = 24
    private static let maximumCharacterEvidencePerToken = 8

    func preflight(
        sourceURL: URL
    ) throws -> PDFDeliveryPreflightAssessment {
        try Task.checkCancellation()
        let sourceIdentity = try auditedFileIdentity(
            at: sourceURL,
            role: "source"
        )

        guard let document = PDFDocument(url: sourceURL),
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        try Self.requireSupportedPageCount(document.pageCount)

        let size = sourceIdentity.byteCount
        if document.isLocked {
            try requireUnchangedFile(
                at: sourceURL,
                expected: sourceIdentity,
                role: "source"
            )
            return PDFDeliveryPreflightAssessment(
                status: .blocked,
                pageCount: document.pageCount,
                byteCount: size,
                fixCount: 0,
                reviewCount: 0,
                items: [
                    PDFDeliveryPreflightItem(
                        id: "locked-source",
                        title: "Password required",
                        detail: "Unlock this working copy first",
                        status: .blocked,
                        repairAction: .createEditableCopy
                    )
                ]
            )
        }

        let snapshot = try snapshot(
            of: document,
            options: .preflight(pageCount: document.pageCount)
        )
        let blankPages = snapshot.renderedPageIndices.compactMap { index in
            snapshot.contentCoverage.indices.contains(index)
                && snapshot.contentCoverage[index] < 0.0005
                ? index
                : nil
        }
        let renderedAllAttemptedPages =
            snapshot.renderedPageCount == snapshot.renderAttemptedPageCount
        let pageRenderingDetail: String
        if snapshot.renderAttemptedPageCount == snapshot.pageCount {
            pageRenderingDetail = renderedAllAttemptedPages
                ? "All \(snapshot.pageCount) pages rendered"
                : "\(snapshot.renderedPageCount) of \(snapshot.pageCount) pages rendered"
        } else {
            pageRenderingDetail = renderedAllAttemptedPages
                ? "Sampled \(snapshot.renderAttemptedPageCount) of \(snapshot.pageCount) pages for quick preflight"
                : "\(snapshot.renderedPageCount) of \(snapshot.renderAttemptedPageCount) sampled pages rendered"
        }

        var items: [PDFDeliveryPreflightItem] = []
        items.append(
            PDFDeliveryPreflightItem(
                id: "source-pages",
                title: "Pages readable",
                detail: pageRenderingDetail,
                status: renderedAllAttemptedPages
                    ? .passed
                    : .blocked
            )
        )
        if snapshot.renderAttemptedPageCount < snapshot.pageCount {
            items.append(
                PDFDeliveryPreflightItem(
                    id: "full-output-audit",
                    title: "Full output audit",
                    detail: "The created copy is still reopened and rendered page by page",
                    status: .passed
                )
            )
        }

        let blankPageDetail: String
        if blankPages.isEmpty {
            blankPageDetail = snapshot.renderAttemptedPageCount
                == snapshot.pageCount
                ? "No blank pages detected"
                : "No blank sampled pages detected"
        } else {
            blankPageDetail = pageList(blankPages)
        }

        items.append(
            PDFDeliveryPreflightItem(
                id: "blank-pages",
                title: "Blank-page check",
                detail: blankPageDetail,
                status: blankPages.isEmpty ? .passed : .review,
                reviewPageIndex: blankPages.first,
                repairAction: blankPages.isEmpty
                    ? nil
                    : .organizePages
            )
        )

        items.append(
            PDFDeliveryPreflightItem(
                id: "editable-layers",
                title: "Editable layers",
                detail: snapshot.annotationCount == 0
                    ? "No editable annotations detected"
                    : "\(snapshot.annotationCount) annotation\(snapshot.annotationCount == 1 ? "" : "s") will be flattened",
                status: snapshot.annotationCount == 0 ? .passed : .willFix
            )
        )
        items.append(contentsOf: try formPreflightItems(
            sourceURL: sourceURL, document: document,
            annotationCount: snapshot.annotationCount
        ))
        items.append(
            PDFDeliveryPreflightItem(
                id: "personal-metadata",
                title: "Personal metadata",
                detail: snapshot.personalMetadataEntryCount == 0
                    ? "No author details detected"
                    : "\(snapshot.personalMetadataEntryCount) entr\(snapshot.personalMetadataEntryCount == 1 ? "y" : "ies") will be removed",
                status: snapshot.personalMetadataEntryCount == 0
                    ? .passed
                    : .willFix
            )
        )
        items.append(
            PDFDeliveryPreflightItem(
                id: "recoverable-text",
                title: "Recoverable text",
                detail: snapshot.textCharacterCount == 0
                    ? "No searchable text layer detected"
                    : "\(snapshot.textCharacterCount) searchable characters will be removed",
                status: snapshot.textCharacterCount == 0
                    ? .passed
                    : .willFix
            )
        )
        if size >= 25_000_000 {
            items.append(
                PDFDeliveryPreflightItem(
                    id: "large-source",
                    title: "Large working copy",
                    detail: "Creation may take longer for \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))",
                    status: .review
                )
            )
        }
        items.append(
            PDFDeliveryPreflightItem(
                id: "source-safety",
                title: "Original preserved",
                detail: "Verify & Share creates a separate copy",
                status: .passed
            )
        )

        let fixCount = items.filter { $0.status == .willFix }.count
        let reviewCount = items.filter { $0.status == .review }.count
        let status: PDFDeliveryPreflightStatus
        if items.contains(where: { $0.status == .blocked }) {
            status = .blocked
        } else if reviewCount > 0 {
            status = .review
        } else {
            status = .ready
        }

        try requireUnchangedFile(
            at: sourceURL,
            expected: sourceIdentity,
            role: "source"
        )
        return PDFDeliveryPreflightAssessment(
            status: status,
            pageCount: snapshot.pageCount,
            byteCount: size,
            fixCount: fixCount,
            reviewCount: reviewCount,
            items: items
        )
    }

    private func formPreflightItems(
        sourceURL: URL, document: PDFDocument, annotationCount: Int
    ) throws -> [PDFDeliveryPreflightItem] {
        var acroForm: CGPDFDictionaryRef?
        let hasAcroForm = document.documentRef?.catalog.map {
            CGPDFDictionaryGetDictionary($0, "AcroForm", &acroForm)
        } ?? false
        guard annotationCount > 0 || hasAcroForm else { return [] }
        guard document.pageCount <= 300, annotationCount <= 5_000 else {
            return [PDFDeliveryPreflightItem(
                id: "form-inspection-limit",
                title: "Form completion not checked",
                detail: "This PDF exceeds the quick form-check limit. Review its fields before sending.",
                status: .review
            )]
        }
        do {
            let report = try PDFFormInspectionService().inspect(url: sourceURL)
            try Task.checkCancellation()
            guard !report.fields.isEmpty || report.hasXFA else { return [] }
            let incomplete = report.fields.filter {
                ($0.isRequired || $0.kind == .signature) && !$0.isComplete
            }
            var items: [PDFDeliveryPreflightItem] = []
            if !report.fields.isEmpty {
                items.append(PDFDeliveryPreflightItem(
                    id: "form-completion",
                    title: incomplete.isEmpty ? "Form fields checked" : "Unfinished form fields",
                    detail: incomplete.isEmpty
                        ? "No empty required or signature fields detected. Signature validity is not checked."
                        : AppLocalization.format(
                            "%lld required or signature fields are empty. Review them before flattening.",
                            incomplete.count
                        ),
                    status: incomplete.isEmpty ? .passed : .review,
                    reviewPageIndex: incomplete.first?.pageIndex
                ))
            }
            if report.hasXFA || !report.issues.isEmpty {
                items.append(PDFDeliveryPreflightItem(
                    id: "form-compatibility",
                    title: "Form compatibility needs review",
                    detail: "Some field appearances, calculations, or scripts need review in a compatible reader.",
                    status: .review,
                    reviewPageIndex: report.fields.first?.pageIndex
                ))
            }
            return items
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return [PDFDeliveryPreflightItem(
                id: "form-inspection-unavailable",
                title: "Form completion not checked",
                detail: "The form could not be fully inspected. Review its fields before sending.",
                status: .review
            )]
        }
    }

    func compare(
        sourceURL: URL,
        revisedURL: URL,
        manualMatches: [PDFManualPageMatch] = [],
        progress: @escaping PDFComparisonProgressHandler = { _ in }
    ) throws -> PDFChangeReview {
        try Task.checkCancellation()
        progress(.starting)
        let sourceIdentity = try auditedFileIdentity(
            at: sourceURL,
            role: "source"
        )
        let revisedIdentity = try auditedFileIdentity(
            at: revisedURL,
            role: "revised"
        )
        guard let sourceDocument = PDFDocument(url: sourceURL),
              let revisedDocument = PDFDocument(url: revisedURL),
              !sourceDocument.isLocked,
              !revisedDocument.isLocked,
              sourceDocument.pageCount > 0,
              revisedDocument.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        try Self.requireSupportedPageCount(sourceDocument.pageCount)
        try Self.requireSupportedPageCount(revisedDocument.pageCount)
        let comparisonOptions = SnapshotOptions.comparison(
            pageCount: max(
                sourceDocument.pageCount,
                revisedDocument.pageCount
            )
        )
        progress(
            PDFComparisonProgress(
                stage: .readingSource,
                completedPageCount: 0,
                totalPageCount: sourceDocument.pageCount,
                fractionCompleted: 0.03
            )
        )
        let sourceSnapshot = try snapshot(
            of: sourceDocument,
            options: comparisonOptions
        ) { completedPageCount, totalPageCount in
            progress(
                PDFComparisonProgress(
                    stage: .readingSource,
                    completedPageCount: completedPageCount,
                    totalPageCount: totalPageCount,
                    fractionCompleted: comparisonFraction(
                        completedPageCount: completedPageCount,
                        totalPageCount: totalPageCount,
                        start: 0.03,
                        end: 0.33
                    )
                )
            )
        }
        try Task.checkCancellation()
        progress(
            PDFComparisonProgress(
                stage: .readingRevised,
                completedPageCount: 0,
                totalPageCount: revisedDocument.pageCount,
                fractionCompleted: 0.33
            )
        )
        let revisedSnapshot = try snapshot(
            of: revisedDocument,
            options: comparisonOptions
        ) { completedPageCount, totalPageCount in
            progress(
                PDFComparisonProgress(
                    stage: .readingRevised,
                    completedPageCount: completedPageCount,
                    totalPageCount: totalPageCount,
                    fractionCompleted: comparisonFraction(
                        completedPageCount: completedPageCount,
                        totalPageCount: totalPageCount,
                        start: 0.33,
                        end: 0.63
                    )
                )
            )
        }
        let review = try changeReview(
            source: sourceSnapshot,
            revised: revisedSnapshot,
            manualMatches: manualMatches,
            progress: progress
        )
        try requireUnchangedFile(
            at: sourceURL,
            expected: sourceIdentity,
            role: "source"
        )
        try requireUnchangedFile(
            at: revisedURL,
            expected: revisedIdentity,
            role: "revised"
        )
        progress(
            PDFComparisonProgress(
                stage: .complete,
                completedPageCount: review.comparedPageCount,
                totalPageCount: review.comparedPageCount,
                fractionCompleted: 1
            )
        )
        return review
    }

    func audit(
        sourceURL: URL,
        outputURL: URL,
        operation: PDFDeliveryOperation,
        unlockPassword: String? = nil,
        timeAnchor: PDFOfficeTimeAnchor = .process
    ) throws -> PDFDeliveryReceipt {
        try Task.checkCancellation()
        guard timeAnchor.evidenceIssuanceDate() != nil else {
            throw PaperPathError.outputVerificationFailed(
                "the device time is earlier than PaperPath's last trusted time; correct the system clock before creating a new Receipt"
            )
        }
        let sourceIdentity = try auditedFileIdentity(
            at: sourceURL,
            role: "source"
        )
        let outputIdentity = try auditedFileIdentity(
            at: outputURL,
            role: "output"
        )

        guard let sourceDocument = PDFDocument(url: sourceURL) else {
            throw PaperPathError.unreadablePDF
        }
        if sourceDocument.isLocked {
            guard let unlockPassword,
                  sourceDocument.unlock(
                    withPassword: unlockPassword
                  )
            else {
                throw PaperPathError.lockedPDF
            }
        }
        guard sourceDocument.pageCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        try Self.requireSupportedPageCount(sourceDocument.pageCount)
        guard let outputDocument = PDFDocument(url: outputURL) else {
            throw PaperPathError.outputVerificationFailed(
                "the new file could not be reopened"
            )
        }

        let outputWasLocked = outputDocument.isLocked
        if outputWasLocked {
            guard let unlockPassword,
                  outputDocument.unlock(withPassword: unlockPassword)
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the password-protected copy could not be reopened"
                )
            }
        }
        try Self.requireSupportedPageCount(outputDocument.pageCount)

        let comparisonOptions = SnapshotOptions.comparison(
            pageCount: max(
                sourceDocument.pageCount,
                outputDocument.pageCount
            )
        )
        let sourceSnapshot = try snapshot(
            of: sourceDocument,
            options: comparisonOptions
        )
        let outputSnapshot = try snapshot(
            of: outputDocument,
            options: comparisonOptions
        )
        let outputChangeReview = try changeReview(
            source: sourceSnapshot,
            revised: outputSnapshot
        )
        let sourceSize = sourceIdentity.byteCount
        let outputSize = outputIdentity.byteCount
        let fingerprint = try sha256(of: outputURL)
        let unexpectedBlankPages = operation == .bookletPrepared
            ? []
            : unexpectedBlankPages(
                sourceCoverage: sourceSnapshot.contentCoverage,
                outputCoverage: outputSnapshot.contentCoverage
            )
        let expectedOutputPageCount = operation == .bookletPrepared
            ? ((sourceSnapshot.pageCount + 3) / 4) * 2
            : sourceSnapshot.pageCount

        var checks: [PDFDeliveryCheck] = []
        checks.append(
            check(
                id: "page-count",
                title: "Page count",
                passed: outputSnapshot.pageCount
                    == expectedOutputPageCount,
                passDetail: operation == .bookletPrepared
                    ? AppLocalization.format(
                        "%lld imposed sides created from %lld source pages",
                        outputSnapshot.pageCount,
                        sourceSnapshot.pageCount
                    )
                    : "\(outputSnapshot.pageCount) of \(sourceSnapshot.pageCount) pages retained",
                failDetail: "Expected \(expectedOutputPageCount) pages; found \(outputSnapshot.pageCount)"
            )
        )
        checks.append(
            check(
                id: "page-rendering",
                title: "Page rendering",
                passed: outputSnapshot.renderedPageCount
                    == outputSnapshot.pageCount,
                passDetail: "Every page reopened and rendered",
                failDetail: "\(outputSnapshot.renderedPageCount) of \(outputSnapshot.pageCount) pages rendered"
            )
        )
        checks.append(
            PDFDeliveryCheck(
                id: "blank-page-risk",
                title: "Unexpected blank pages",
                detail: unexpectedBlankPages.isEmpty
                    ? "No newly blank pages detected"
                    : pageList(unexpectedBlankPages),
                status: unexpectedBlankPages.isEmpty ? .passed : .failed
            )
        )
        checks.append(
            changeReviewCheck(
                outputChangeReview,
                operation: operation
            )
        )
        if operation == .unlocked {
            let structureService = PDFDocumentStructureService()
            let sourceStructure = try structureService
                .preservationSignature(
                    in: sourceURL,
                    unlockPassword: unlockPassword,
                    includePageLabels: true
                )
            let outputStructure = try structureService
                .preservationSignature(
                    in: outputURL,
                    includePageLabels: true
                )
            checks.append(
                check(
                    id: "document-structure",
                    title: "Document structure",
                    passed: outputStructure == sourceStructure,
                    passDetail:
                        "Attachments, page labels, review objects, and outlines retained",
                    failDetail:
                        "Attachments, page labels, review objects, or outlines changed"
                )
            )
        }

        let regeneratesPageAppearance = operation == .compressed
            || operation == .redacted
            || operation == .flattened
            || operation == .safeShare
            || operation == .printPrepared
            || operation == .bookletPrepared
        if regeneratesPageAppearance {
            let formItems = try formPreflightItems(
                sourceURL: sourceURL, document: sourceDocument,
                annotationCount: sourceSnapshot.annotationCount
            )
            checks.append(contentsOf: formItems.filter {
                $0.status == .review
            }.map {
                PDFDeliveryCheck(
                    id: "source-\($0.id)", title: $0.title,
                    detail: $0.detail, status: .warning
                )
            })
        }
        checks.append(
            PDFDeliveryCheck(
                id: "annotations",
                title: "Editable annotations",
                detail: regeneratesPageAppearance
                    ? "\(outputSnapshot.annotationCount) editable annotations remain"
                    : "\(outputSnapshot.annotationCount) annotations retained",
                status: regeneratesPageAppearance
                    ? (
                        outputSnapshot.annotationCount == 0
                            ? .passed
                            : .failed
                    )
                    : .notApplicable
            )
        )

        let requiresTextRemoval = operation == .redacted
            || operation == .flattened
            || operation == .safeShare
        let sourceHadText = sourceSnapshot.textCharacterCount > 0
        if requiresTextRemoval {
            checks.append(
                check(
                    id: "text-layer",
                    title: "Recoverable text layer",
                    passed: outputSnapshot.textCharacterCount == 0,
                    passDetail: "No searchable text layer remains",
                    failDetail: "\(outputSnapshot.textCharacterCount) text characters remain"
                )
            )
        } else if operation == .compressed, sourceHadText {
            checks.append(
                PDFDeliveryCheck(
                    id: "text-layer",
                    title: "Searchable text",
                    detail: outputSnapshot.textCharacterCount == 0
                        ? "Compression converted pages to images"
                        : "Searchable text remains available",
                    status: outputSnapshot.textCharacterCount == 0
                        ? .warning
                        : .passed
                )
            )
        } else if (
            operation == .printPrepared
                || operation == .bookletPrepared
        ), sourceHadText {
            checks.append(
                PDFDeliveryCheck(
                    id: "text-layer",
                    title: "Searchable text",
                    detail: outputSnapshot.textCharacterCount == 0
                        ? "Page appearance retained; searchable text was not recoverable"
                        : "Searchable text remains available",
                    status: outputSnapshot.textCharacterCount == 0
                        ? .warning
                        : .passed
                )
            )
        }

        if regeneratesPageAppearance {
            checks.append(
                check(
                    id: "personal-metadata",
                    title: "Personal metadata",
                    passed: outputSnapshot.personalMetadataEntryCount == 0,
                    passDetail: "No author, title, subject, or keywords remain",
                    failDetail: "\(outputSnapshot.personalMetadataEntryCount) personal metadata entries remain"
                )
            )
        } else {
            checks.append(
                PDFDeliveryCheck(
                    id: "personal-metadata",
                    title: "Personal metadata",
                    detail: outputSnapshot.personalMetadataEntryCount == 0
                        ? "No personal metadata detected"
                        : "\(outputSnapshot.personalMetadataEntryCount) entries retained by password protection",
                    status: outputSnapshot.personalMetadataEntryCount == 0
                        ? .passed
                        : .warning
                )
            )
        }

        let encryptionPassed: Bool
        switch operation {
        case .protected:
            encryptionPassed = outputWasLocked
                && outputDocument.isEncrypted
        case .unlocked:
            encryptionPassed = !outputWasLocked
                && !outputDocument.isEncrypted
        default:
            encryptionPassed = true
        }
        let encryptionDetail: String
        let encryptionStatus: PDFDeliveryCheckStatus
        switch operation {
        case .protected:
            encryptionDetail = encryptionPassed
                ? "Password required and verified"
                : "Password protection could not be verified"
            encryptionStatus = encryptionPassed ? .passed : .failed
        case .unlocked:
            encryptionDetail = encryptionPassed
                ? "Password removed from the private copy"
                : "The private copy still requires a password"
            encryptionStatus = encryptionPassed ? .passed : .failed
        default:
            encryptionDetail = "Not requested for this copy"
            encryptionStatus = .notApplicable
        }
        checks.append(
            PDFDeliveryCheck(
                id: "encryption",
                title: "Password encryption",
                detail: encryptionDetail,
                status: encryptionStatus
            )
        )
        checks.append(
            PDFDeliveryCheck(
                id: "fingerprint",
                title: "SHA-256 fingerprint",
                detail: String(fingerprint.prefix(12)).uppercased(),
                status: fingerprint.isEmpty ? .failed : .passed
            )
        )

        try requireUnchangedFile(
            at: sourceURL,
            expected: sourceIdentity,
            role: "source"
        )
        try requireUnchangedFile(
            at: outputURL,
            expected: outputIdentity,
            role: "output"
        )
        if let failed = checks.first(where: { $0.status == .failed }) {
            throw PaperPathError.outputVerificationFailed(failed.detail)
        }

        guard let trustedCreatedAt =
                timeAnchor.evidenceIssuanceDate()
        else {
            throw PaperPathError.outputVerificationFailed(
                "the device time is earlier than PaperPath's last trusted time; correct the system clock before creating a new Receipt"
            )
        }
        return PDFDeliveryReceipt(
            id: UUID(),
            operation: operation,
            createdAt: Date(
                timeIntervalSince1970: floor(
                    trustedCreatedAt.timeIntervalSince1970
                )
            ),
            sourcePageCount: sourceSnapshot.pageCount,
            outputPageCount: outputSnapshot.pageCount,
            renderedPageCount: outputSnapshot.renderedPageCount,
            sourceByteCount: sourceSize,
            outputByteCount: outputSize,
            unexpectedBlankPageIndices: unexpectedBlankPages,
            annotationCount: outputSnapshot.annotationCount,
            textCharacterCount: outputSnapshot.textCharacterCount,
            personalMetadataEntryCount: outputSnapshot.personalMetadataEntryCount,
            isEncrypted: outputWasLocked && outputDocument.isEncrypted,
            sha256: fingerprint,
            checks: checks,
            changeReview: outputChangeReview
        )
    }

    private func snapshot(
        of document: PDFDocument,
        options: SnapshotOptions = .complete,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Snapshot {
        try Self.requireSupportedPageCount(document.pageCount)
        var renderedPageCount = 0
        var renderAttemptedPageCount = 0
        var renderedPageIndices: [Int] = []
        var coverage: [Double] = []
        var annotationCount = 0
        var textCharacterCount = 0
        var pageSnapshots: [PageSnapshot] = []
        coverage.reserveCapacity(document.pageCount)
        pageSnapshots.reserveCapacity(document.pageCount)

        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let shouldRender = options.shouldRender(pageIndex: index)
            if shouldRender {
                renderAttemptedPageCount += 1
            }
            guard let page = document.page(at: index) else {
                throw PaperPathError.invalidPage
            }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.origin.x.isFinite,
                  bounds.origin.y.isFinite,
                  bounds.width.isFinite,
                  bounds.height.isFinite,
                  bounds.width > 0,
                  bounds.height > 0
            else {
                throw PaperPathError.invalidPage
            }
            let pageSnapshot: PageSnapshot = autoreleasepool {
                let annotations = page.annotations.count
                let rawPageText = page.string ?? ""
                let pageText = normalizedText(rawPageText)
                let characters = pageText.count
                let textFingerprint = Data(
                    SHA256.hash(data: Data(pageText.utf8))
                )
                let textFragments = options.shouldCaptureTextFragments(
                    pageIndex: index,
                    pageCount: document.pageCount
                )
                    ? textFragments(
                        in: page,
                        text: rawPageText,
                        pageBounds: bounds,
                        limit: options.maximumTextFragments
                    )
                    : []
                let pageLabelFingerprint = pageLabelFingerprint(
                    page.label,
                    pageIndex: index
                )
                let stableMarkerFingerprint = stableMarkerFingerprint(
                    textFragments
                )
                let vectorFragments: [PDFVectorFragment]?
                if options.shouldCaptureVectorFragments(
                    pageIndex: index,
                    pageCount: document.pageCount
                ),
                   let documentReference = document.documentRef,
                   let pageReference = documentReference.page(
                       at: index + 1
                   ) {
                    vectorFragments = pdfVectorFragments(
                        in: pageReference,
                        pageBounds: bounds,
                        maximumFragments:
                            options.maximumVectorFragments
                    )
                } else {
                    vectorFragments = nil
                }
                guard shouldRender else {
                    return PageSnapshot(
                        rendered: false,
                        coverage: 0,
                        annotationCount: annotations,
                        textCharacterCount: characters,
                        textFingerprint: textFingerprint,
                        textFragments: textFragments,
                        pageLabelFingerprint: pageLabelFingerprint,
                        stableMarkerFingerprint: stableMarkerFingerprint,
                        barcodeFingerprint: nil,
                        pageSize: bounds.size,
                        rotation: page.rotation,
                        vectorFragments: vectorFragments,
                        visualSamples: [],
                        alignmentSamples: []
                    )
                }
                let target = fittedSize(
                    bounds.size,
                    longestEdge: options.renderLongestEdge
                )
                let image = page.thumbnail(
                    of: target,
                    for: .cropBox
                )
                guard image.size.width > 0,
                      image.size.height > 0,
                      let visual = visualSignature(
                          of: image,
                          sampleSide: options.visualSampleSide
                      )
                else {
                    return PageSnapshot(
                        rendered: false,
                        coverage: 0,
                        annotationCount: annotations,
                        textCharacterCount: characters,
                        textFingerprint: textFingerprint,
                        textFragments: textFragments,
                        pageLabelFingerprint: pageLabelFingerprint,
                        stableMarkerFingerprint: stableMarkerFingerprint,
                        barcodeFingerprint: nil,
                        pageSize: bounds.size,
                        rotation: page.rotation,
                        vectorFragments: vectorFragments,
                        visualSamples: [],
                        alignmentSamples: []
                    )
                }
                return PageSnapshot(
                    rendered: true,
                    coverage: visual.coverage,
                    annotationCount: annotations,
                    textCharacterCount: characters,
                    textFingerprint: textFingerprint,
                    textFragments: textFragments,
                    pageLabelFingerprint: pageLabelFingerprint,
                    stableMarkerFingerprint: stableMarkerFingerprint,
                    barcodeFingerprint: options.detectBarcodes
                        && characters < 8
                        ? barcodeFingerprint(image)
                        : nil,
                    pageSize: bounds.size,
                    rotation: page.rotation,
                    vectorFragments: vectorFragments,
                    visualSamples: visual.samples,
                    alignmentSamples: visual.alignmentSamples
                )
            }
            try Task.checkCancellation()
            annotationCount = saturatingAdd(
                annotationCount,
                pageSnapshot.annotationCount
            )
            textCharacterCount = saturatingAdd(
                textCharacterCount,
                pageSnapshot.textCharacterCount
            )
            if pageSnapshot.rendered {
                renderedPageCount += 1
                renderedPageIndices.append(index)
            }
            coverage.append(pageSnapshot.coverage)
            pageSnapshots.append(pageSnapshot)
            let completedPageCount = index + 1
            if shouldPublishComparisonProgress(
                completedPageCount: completedPageCount,
                totalPageCount: document.pageCount
            ) {
                progress?(
                    completedPageCount,
                    document.pageCount
                )
            }
        }

        return Snapshot(
            pageCount: document.pageCount,
            renderedPageCount: renderedPageCount,
            renderAttemptedPageCount: renderAttemptedPageCount,
            renderedPageIndices: renderedPageIndices,
            contentCoverage: coverage,
            annotationCount: annotationCount,
            textCharacterCount: textCharacterCount,
            personalMetadataEntryCount: personalMetadataCount(in: document),
            pages: pageSnapshots
        )
    }

    private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : max(0, sum)
    }

    private func personalMetadataCount(in document: PDFDocument) -> Int {
        let attributes = document.documentAttributes ?? [:]
        let keys: [PDFDocumentAttribute] = [
            .authorAttribute,
            .titleAttribute,
            .subjectAttribute,
            .keywordsAttribute
        ]
        return keys.reduce(into: 0) { count, key in
            guard let value = attributes[key] else { return }
            if let text = value as? String,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            if let values = value as? [Any], values.isEmpty {
                return
            }
            count += 1
        }
    }

    private func unexpectedBlankPages(
        sourceCoverage: [Double],
        outputCoverage: [Double]
    ) -> [Int] {
        let count = min(sourceCoverage.count, outputCoverage.count)
        return (0..<count).filter { index in
            let source = sourceCoverage[index]
            let output = outputCoverage[index]
            return source > 0.0015
                && output < 0.0005
                && output < source * 0.08
        }
    }

    private func visualSignature(
        of image: UIImage,
        sampleSide: Int
    ) -> VisualSignature? {
        guard let source = image.cgImage else { return nil }
        let width = sampleSide
        let height = sampleSide
        let bytesPerPixel = 4
        var pixels = [UInt8](
            repeating: 255,
            count: width * height * bytesPerPixel
        )
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        context.draw(
            source,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        var contentPixels = 0
        let totalPixels = width * height
        var samples: [UInt8] = []
        samples.reserveCapacity(totalPixels * 3)
        let alignmentGrid = 6
        let alignmentCellSide = width / alignmentGrid
        var alignmentTotals = [Int](
            repeating: 0,
            count: alignmentGrid * alignmentGrid
        )
        for offset in stride(
            from: 0,
            to: pixels.count,
            by: bytesPerPixel
        ) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            samples.append(UInt8(red))
            samples.append(UInt8(green))
            samples.append(UInt8(blue))
            let pixelIndex = offset / bytesPerPixel
            let x = pixelIndex % width
            let y = pixelIndex / width
            let alignmentIndex =
                (y / alignmentCellSide) * alignmentGrid
                + (x / alignmentCellSide)
            alignmentTotals[alignmentIndex] +=
                (red * 77 + green * 150 + blue * 29) >> 8
            let darkest = min(red, green, blue)
            let lightest = max(red, green, blue)
            if darkest < 242 || lightest - darkest > 10 {
                contentPixels += 1
            }
        }
        let pixelsPerAlignmentCell =
            alignmentCellSide * alignmentCellSide
        return VisualSignature(
            coverage: Double(contentPixels) / Double(totalPixels),
            samples: samples,
            alignmentSamples: alignmentTotals.map {
                UInt8($0 / pixelsPerAlignmentCell)
            }
        )
    }

    func normalizedText(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
    }

    private func textFragments(
        in page: PDFPage,
        text: String,
        pageBounds: CGRect,
        limit: Int
    ) -> [TextFragment] {
        guard limit > 0,
              !text.isEmpty,
              pageBounds.width > 0,
              pageBounds.height > 0
        else { return [] }

        var fragments: [TextFragment] = []
        fragments.reserveCapacity(min(limit, 160))
        var remainingCharacterBudget = min(2_048, limit * 8)
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords]
        ) { substring, range, _, stop in
            guard !Task.isCancelled else {
                stop = true
                return
            }
            guard fragments.count < limit else {
                stop = true
                return
            }
            guard let substring else { return }
            let value = normalizedToken(substring)
            let comparison = comparisonToken(substring)
            guard !value.isEmpty else { return }
            let selectionRange = NSRange(range, in: text)
            guard let selection = page.selection(for: selectionRange)
            else { return }
            let bounds = selection.bounds(for: page)
                .intersection(pageBounds)
            guard !bounds.isNull,
                  bounds.width > 0.5,
                  bounds.height > 0.5
            else { return }
            let region = PDFDifferenceRegion(
                x: Double(
                    (bounds.minX - pageBounds.minX)
                        / pageBounds.width
                ),
                y: Double(
                    (pageBounds.maxY - bounds.maxY)
                        / pageBounds.height
                ),
                width: Double(bounds.width / pageBounds.width),
                height: Double(bounds.height / pageBounds.height),
                intensity: 1
            )
            fragments.append(
                TextFragment(
                    text: String(substring.prefix(80)),
                    normalized: value,
                    comparison: comparison,
                    region: region,
                    characters: characterFragments(
                        in: page,
                        text: text,
                        range: range,
                        pageBounds: pageBounds,
                        remainingBudget: &remainingCharacterBudget
                    )
                )
            )
        }
        return fragments
    }

    func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    func comparisonToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    private func characterFragments(
        in page: PDFPage,
        text: String,
        range: Range<String.Index>,
        pageBounds: CGRect,
        remainingBudget: inout Int
    ) -> [CharacterFragment] {
        guard remainingBudget > 0 else { return [] }
        var fragments: [CharacterFragment] = []
        fragments.reserveCapacity(
            min(
                48,
                text.distance(
                    from: range.lowerBound,
                    to: range.upperBound
                )
            )
        )
        var cursor = range.lowerBound
        while cursor < range.upperBound,
              fragments.count < 48,
              remainingBudget > 0 {
            if Task.isCancelled { break }
            let next = text.index(after: cursor)
            let characterRange = cursor..<next
            let value = String(text[characterRange])
                .precomposedStringWithCanonicalMapping
            let selectionRange = NSRange(characterRange, in: text)
            if let selection = page.selection(for: selectionRange) {
                let bounds = selection.bounds(for: page)
                    .intersection(pageBounds)
                if !bounds.isNull,
                   bounds.width > 0.2,
                   bounds.height > 0.5 {
                    fragments.append(
                        CharacterFragment(
                            text: value,
                            region: normalizedRegion(
                                bounds,
                                in: pageBounds
                            )
                        )
                    )
                    remainingBudget -= 1
                }
            }
            cursor = next
        }
        return fragments
    }

    func normalizedRegion(
        _ bounds: CGRect,
        in pageBounds: CGRect
    ) -> PDFDifferenceRegion {
        PDFDifferenceRegion(
            x: Double(
                (bounds.minX - pageBounds.minX) / pageBounds.width
            ),
            y: Double(
                (pageBounds.maxY - bounds.maxY) / pageBounds.height
            ),
            width: Double(bounds.width / pageBounds.width),
            height: Double(bounds.height / pageBounds.height),
            intensity: 1
        )
    }

    private func barcodeFingerprint(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [
            .qr,
            .aztec,
            .dataMatrix,
            .pdf417,
            .code128
        ]
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let payloads = (request.results ?? []).compactMap {
            observation -> String? in
            guard let payload = observation.payloadStringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !payload.isEmpty
            else { return nil }
            return String(payload.prefix(256))
                .precomposedStringWithCanonicalMapping
        }
        guard !payloads.isEmpty else { return nil }
        let material = Array(Set(payloads)).sorted()
            .joined(separator: "|")
        return Data(
            SHA256.hash(
                data: Data("barcode:\(material)".utf8)
            )
        )
    }

    func pageLabelFingerprint(
        _ label: String?,
        pageIndex: Int
    ) -> Data? {
        guard let label else { return nil }
        let normalized = normalizedToken(label)
        guard !normalized.isEmpty else { return nil }
        let defaultLabels = [
            "\(pageIndex + 1)",
            "page \(pageIndex + 1)"
        ]
        guard !defaultLabels.contains(normalized) else { return nil }
        return Data(
            SHA256.hash(
                data: Data("label:\(normalized)".utf8)
            )
        )
    }

    func stableMarkerFingerprint(
        _ fragments: [TextFragment]
    ) -> Data? {
        let markers = fragments.compactMap { fragment -> String? in
            let value = fragment.normalized
            guard value.count >= 4,
                  value.count <= 48,
                  value.unicodeScalars.contains(
                    where: CharacterSet.decimalDigits.contains
                  )
            else { return nil }
            let letterCount = value.unicodeScalars.filter(
                CharacterSet.letters.contains
            ).count
            let digitCount = value.unicodeScalars.filter(
                CharacterSet.decimalDigits.contains
            ).count
            guard digitCount >= 3 || letterCount >= 2 else {
                return nil
            }
            return value
        }
        guard !markers.isEmpty else { return nil }
        let material = markers.prefix(4).joined(separator: "|")
        return Data(
            SHA256.hash(
                data: Data("marker:\(material)".utf8)
            )
        )
    }

    func changeReview(
        source: Snapshot,
        revised: Snapshot,
        manualMatches: [PDFManualPageMatch] = [],
        progress: @escaping PDFComparisonProgressHandler = { _ in }
    ) throws -> PDFChangeReview {
        try Task.checkCancellation()
        let matchingPageCount = max(
            source.pageCount,
            revised.pageCount
        )
        progress(
            PDFComparisonProgress(
                stage: .matchingPages,
                completedPageCount: 0,
                totalPageCount: matchingPageCount,
                fractionCompleted: 0.63
            )
        )
        let aligned = try alignedPages(
            source: source.pages,
            revised: revised.pages,
            manualMatches: manualMatches
        )
        progress(
            PDFComparisonProgress(
                stage: .matchingPages,
                completedPageCount: aligned.count,
                totalPageCount: aligned.count,
                fractionCompleted: 0.72
            )
        )
        var changes: [PDFPageChange] = []
        var pageMatches: [PDFPageMatch] = []
        var comparedPageCount = 0
        changes.reserveCapacity(aligned.count)
        pageMatches.reserveCapacity(aligned.count)

        for (sequenceIndex, pair) in aligned.enumerated() {
            if sequenceIndex.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            let sourcePage = pair.sourceIndex.map {
                source.pages[$0]
            }
            let revisedPage = pair.revisedIndex.map {
                revised.pages[$0]
            }
            if sourcePage != nil, revisedPage != nil {
                comparedPageCount += 1
            }
            let change = try pageChange(
                sequenceIndex: sequenceIndex,
                sourceIndex: pair.sourceIndex,
                revisedIndex: pair.revisedIndex,
                source: sourcePage,
                revised: revisedPage,
                matchBasis: pair.basis
            )
            let kind = change?.resolvedMatchKind ?? .unchanged
            pageMatches.append(
                PDFPageMatch(
                    id: sequenceIndex,
                    sourcePageIndex: pair.sourceIndex,
                    revisedPageIndex: pair.revisedIndex,
                    kind: kind,
                    basis: pair.basis
                )
            )
            if let change {
                changes.append(change)
            }
            let completedPageCount = sequenceIndex + 1
            if shouldPublishComparisonProgress(
                completedPageCount: completedPageCount,
                totalPageCount: aligned.count
            ) {
                progress(
                    PDFComparisonProgress(
                        stage: .inspectingChanges,
                        completedPageCount: completedPageCount,
                        totalPageCount: aligned.count,
                        fractionCompleted: comparisonFraction(
                            completedPageCount: completedPageCount,
                            totalPageCount: aligned.count,
                            start: 0.72,
                            end: 0.99
                        )
                    )
                )
            }
        }

        return PDFChangeReview(
            sourcePageCount: source.pageCount,
            revisedPageCount: revised.pageCount,
            comparedPageCount: comparedPageCount,
            changes: changes,
            pageMatches: pageMatches,
            manualPageMatches: manualMatches.isEmpty
                ? nil
                : pageMatches.compactMap { match in
                    guard match.basis == .manual,
                          let sourcePageIndex =
                            match.sourcePageIndex,
                          let revisedPageIndex =
                            match.revisedPageIndex
                    else { return nil }
                    return PDFManualPageMatch(
                        sourcePageIndex: sourcePageIndex,
                        revisedPageIndex: revisedPageIndex
                    )
                }
        )
    }

    private func shouldPublishComparisonProgress(
        completedPageCount: Int,
        totalPageCount: Int
    ) -> Bool {
        guard totalPageCount > 0,
              completedPageCount > 0
        else { return false }
        let stride = max(
            1,
            Int(ceil(Double(totalPageCount) / 200))
        )
        return completedPageCount == 1
            || completedPageCount >= totalPageCount
            || completedPageCount.isMultiple(of: stride)
    }

    private func comparisonFraction(
        completedPageCount: Int,
        totalPageCount: Int,
        start: Double,
        end: Double
    ) -> Double {
        guard totalPageCount > 0 else { return end }
        let completed = min(
            max(0, completedPageCount),
            totalPageCount
        )
        let pageFraction =
            Double(completed) / Double(totalPageCount)
        return start + ((end - start) * pageFraction)
    }

    func pageChange(
        sequenceIndex: Int,
        sourceIndex: Int?,
        revisedIndex: Int?,
        source: PageSnapshot?,
        revised: PageSnapshot?,
        matchBasis: PDFPageMatchBasis?
    ) throws -> PDFPageChange? {
        guard let source, let revised else {
            return PDFPageChange(
                pageIndex: revisedIndex ?? sourceIndex ?? sequenceIndex,
                sourcePageIndex: sourceIndex,
                revisedPageIndex: revisedIndex,
                matchKind: source == nil ? .inserted : .removed,
                sourceExists: source != nil,
                revisedExists: revised != nil,
                visibleDifference: 1,
                changedPixelRatio: 1,
                geometryChanged: true,
                textChanged: true,
                sourceTextCharacterCount:
                    source?.textCharacterCount ?? 0,
                revisedTextCharacterCount:
                    revised?.textCharacterCount ?? 0,
                matchBasis: matchBasis
            )
        }

        let geometryChanged = pageGeometryChanged(source, revised)
        let visual = detailedVisualDifference(
            source.visualSamples,
            revised.visualSamples
        )
        let textChanged = source.textFingerprint
            != revised.textFingerprint
        let textDifferences = textChanged
            ? locatedTextDifferences(
                source: source.textFragments,
                revised: revised.textFragments
            )
            : (
                source: [],
                revised: [],
                sourceOmittedCount: 0,
                revisedOmittedCount: 0
            )
        try Task.checkCancellation()
        let vectorDifferences = locatedVectorDifferences(
            source: source.vectorFragments,
            revised: revised.vectorFragments,
            visualRegions: visual.regions ?? []
        )
        let candidate = PDFPageChange(
            pageIndex: revisedIndex ?? sourceIndex ?? sequenceIndex,
            sourcePageIndex: sourceIndex,
            revisedPageIndex: revisedIndex,
            matchKind: .modified,
            sourceExists: true,
            revisedExists: true,
            visibleDifference: visual.meanDifference,
            changedPixelRatio: visual.changedPixelRatio,
            geometryChanged: geometryChanged,
            textChanged: textChanged,
            sourceTextCharacterCount: source.textCharacterCount,
            revisedTextCharacterCount: revised.textCharacterCount,
            differenceRegions: visual.regions,
            sourceTextDifferences: textDifferences.source,
            revisedTextDifferences: textDifferences.revised,
            sourceTextDifferenceOmittedCount:
                textDifferences.sourceOmittedCount,
            revisedTextDifferenceOmittedCount:
                textDifferences.revisedOmittedCount,
            sourceVectorDifferences: vectorDifferences.source,
            revisedVectorDifferences: vectorDifferences.revised,
            matchBasis: matchBasis
        )
        return candidate.isVisibleChange || candidate.textChanged
            ? candidate
            : nil
    }

    func alignedPages(
        source: [PageSnapshot],
        revised: [PageSnapshot],
        manualMatches: [PDFManualPageMatch] = []
    ) throws -> [AlignedPage] {
        try Task.checkCancellation()
        let anchors = try stableAnchors(
            source: source,
            revised: revised,
            manualMatches: manualMatches
        )
        var result: [AlignedPage] = []
        var sourceCursor = 0
        var revisedCursor = 0

        for (anchorIndex, anchor) in anchors.enumerated() {
            if anchorIndex.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            result.append(
                contentsOf: try alignSegment(
                    source: source,
                    sourceRange: sourceCursor..<anchor.source,
                    revised: revised,
                    revisedRange: revisedCursor..<anchor.revised
                )
            )
            result.append(
                AlignedPage(
                    sourceIndex: anchor.source,
                    revisedIndex: anchor.revised,
                    basis: anchor.basis
                )
            )
            sourceCursor = anchor.source + 1
            revisedCursor = anchor.revised + 1
        }
        result.append(
            contentsOf: try alignSegment(
                source: source,
                sourceRange: sourceCursor..<source.count,
                revised: revised,
                revisedRange: revisedCursor..<revised.count
            )
        )
        return result
    }

    func stableAnchors(
        source: [PageSnapshot],
        revised: [PageSnapshot],
        manualMatches: [PDFManualPageMatch] = []
    ) throws -> [AnchorCandidate] {
        let manualAnchors = try validatedManualAnchors(
            manualMatches,
            sourcePageCount: source.count,
            revisedPageCount: revised.count
        )
        let sourceKeys = try pageAnchorKeys(source)
        let revisedKeys = try pageAnchorKeys(revised)
        let sourceExact = try uniqueKeyIndices(sourceKeys)
        let revisedExact = try uniqueKeyIndices(revisedKeys)
        var candidates = sourceExact.compactMap {
            key,
            sourceIndex -> AnchorCandidate? in
            guard let revisedIndex = revisedExact[key] else {
                return nil
            }
            return AnchorCandidate(
                source: sourceIndex,
                revised: revisedIndex,
                basis: .exactContent
            )
        }
        let manualSourcePages = Set(manualAnchors.map(\.source))
        let manualRevisedPages = Set(manualAnchors.map(\.revised))
        candidates.removeAll {
            manualSourcePages.contains($0.source)
                || manualRevisedPages.contains($0.revised)
                || !repeatedAnchor(
                    sourceIndex: $0.source,
                    revisedIndex: $0.revised,
                    isCompatibleWith: manualAnchors
                )
        }
        var occupiedSource = Set(candidates.map(\.source))
            .union(manualSourcePages)
        var occupiedRevised = Set(candidates.map(\.revised))
            .union(manualRevisedPages)

        try appendUniqueAnchors(
            sourceKeys: source.map(\.pageLabelFingerprint),
            revisedKeys: revised.map(\.pageLabelFingerprint),
            basis: .pageLabel,
            requiredAnchors: manualAnchors,
            candidates: &candidates,
            occupiedSource: &occupiedSource,
            occupiedRevised: &occupiedRevised
        )
        try appendUniqueAnchors(
            sourceKeys: source.map(\.stableMarkerFingerprint),
            revisedKeys: revised.map(\.stableMarkerFingerprint),
            basis: .textMarker,
            requiredAnchors: manualAnchors,
            candidates: &candidates,
            occupiedSource: &occupiedSource,
            occupiedRevised: &occupiedRevised
        )
        try appendUniqueAnchors(
            sourceKeys: source.map(\.barcodeFingerprint),
            revisedKeys: revised.map(\.barcodeFingerprint),
            basis: .barcode,
            requiredAnchors: manualAnchors,
            candidates: &candidates,
            occupiedSource: &occupiedSource,
            occupiedRevised: &occupiedRevised
        )
        let sourceContext = try contextualAnchorKeys(
            pages: source,
            keys: sourceKeys
        )
        let revisedContext = try contextualAnchorKeys(
            pages: revised,
            keys: revisedKeys
        )
        let sourceContextUnique = try uniqueKeyIndices(sourceContext)
        let revisedContextUnique = try uniqueKeyIndices(revisedContext)
        for (offset, entry) in sourceContextUnique.enumerated() {
            if offset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let (key, sourceIndex) = entry
            guard !occupiedSource.contains(sourceIndex),
                  let revisedIndex = revisedContextUnique[key],
                  !occupiedRevised.contains(revisedIndex),
                  repeatedAnchor(
                    sourceIndex: sourceIndex,
                    revisedIndex: revisedIndex,
                    isCompatibleWith: manualAnchors
                  )
            else { continue }
            candidates.append(
                AnchorCandidate(
                    source: sourceIndex,
                    revised: revisedIndex,
                    basis: .context
                )
            )
            occupiedSource.insert(sourceIndex)
            occupiedRevised.insert(revisedIndex)
        }
        candidates.sort {
            if $0.source != $1.source {
                return $0.source < $1.source
            }
            return $0.revised < $1.revised
        }
        let stableCandidates = try anchors(
            candidates,
            constrainedBy: manualAnchors,
            sourcePageCount: source.count,
            revisedPageCount: revised.count
        )
        candidates = stableCandidates
        occupiedSource = Set(stableCandidates.map(\.source))
        occupiedRevised = Set(stableCandidates.map(\.revised))
        try appendRepeatedOrderAnchors(
            sourceKeys: sourceKeys,
            revisedKeys: revisedKeys,
            stableAnchors: stableCandidates,
            candidates: &candidates,
            occupiedSource: &occupiedSource,
            occupiedRevised: &occupiedRevised
        )
        candidates.sort {
            if $0.source != $1.source {
                return $0.source < $1.source
            }
            return $0.revised < $1.revised
        }
        return try longestIncreasingAnchors(candidates)
    }

    func validatedManualAnchors(
        _ matches: [PDFManualPageMatch],
        sourcePageCount: Int,
        revisedPageCount: Int
    ) throws -> [AnchorCandidate] {
        guard matches.count <= min(
            sourcePageCount,
            revisedPageCount
        ) else {
            throw PaperPathError.insufficientSelection(
                "Manual page matches exceed the available pages."
            )
        }
        let ordered = matches.sorted {
            if $0.sourcePageIndex != $1.sourcePageIndex {
                return $0.sourcePageIndex < $1.sourcePageIndex
            }
            return $0.revisedPageIndex < $1.revisedPageIndex
        }
        var previousSource = -1
        var previousRevised = -1
        var anchors: [AnchorCandidate] = []
        anchors.reserveCapacity(ordered.count)
        for (index, match) in ordered.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard match.isValid(
                sourcePageCount: sourcePageCount,
                revisedPageCount: revisedPageCount
            ) else {
                throw PaperPathError.insufficientSelection(
                    "A manually matched page is no longer available."
                )
            }
            guard match.sourcePageIndex > previousSource,
                  match.revisedPageIndex > previousRevised
            else {
                throw PaperPathError.insufficientSelection(
                    "Manual page matches must preserve page order."
                )
            }
            anchors.append(
                AnchorCandidate(
                    source: match.sourcePageIndex,
                    revised: match.revisedPageIndex,
                    basis: .manual
                )
            )
            previousSource = match.sourcePageIndex
            previousRevised = match.revisedPageIndex
        }
        return anchors
    }

    func anchors(
        _ candidates: [AnchorCandidate],
        constrainedBy manualAnchors: [AnchorCandidate],
        sourcePageCount: Int,
        revisedPageCount: Int
    ) throws -> [AnchorCandidate] {
        guard !manualAnchors.isEmpty else {
            return try longestIncreasingAnchors(candidates)
        }
        var result: [AnchorCandidate] = []
        var sourceLowerBound = -1
        var revisedLowerBound = -1
        var candidateCursor = 0
        for boundaryIndex in 0...manualAnchors.count {
            if boundaryIndex.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            let sourceUpperBound = boundaryIndex
                < manualAnchors.count
                ? manualAnchors[boundaryIndex].source
                : sourcePageCount
            let revisedUpperBound = boundaryIndex
                < manualAnchors.count
                ? manualAnchors[boundaryIndex].revised
                : revisedPageCount
            while candidateCursor < candidates.count,
                  candidates[candidateCursor].source <= sourceLowerBound {
                candidateCursor += 1
            }
            let segmentStart = candidateCursor
            while candidateCursor < candidates.count,
                  candidates[candidateCursor].source < sourceUpperBound {
                candidateCursor += 1
            }
            let segmentCandidates = candidates[
                segmentStart..<candidateCursor
            ].filter {
                $0.revised > revisedLowerBound
                    && $0.revised < revisedUpperBound
            }
            result.append(
                contentsOf: try longestIncreasingAnchors(
                    segmentCandidates
                )
            )
            guard boundaryIndex < manualAnchors.count else {
                continue
            }
            let manual = manualAnchors[boundaryIndex]
            result.append(manual)
            sourceLowerBound = manual.source
            revisedLowerBound = manual.revised
        }
        return result
    }

    func pageAnchorKeys(
        _ pages: [PageSnapshot]
    ) throws -> [Data?] {
        var keys: [Data?] = []
        keys.reserveCapacity(pages.count)
        for (index, page) in pages.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            keys.append(pageAnchorKey(page))
        }
        return keys
    }

    func appendUniqueAnchors(
        sourceKeys: [Data?],
        revisedKeys: [Data?],
        basis: PDFPageMatchBasis,
        requiredAnchors: [AnchorCandidate] = [],
        candidates: inout [AnchorCandidate],
        occupiedSource: inout Set<Int>,
        occupiedRevised: inout Set<Int>
    ) throws {
        let sourceUnique = try uniqueKeyIndices(sourceKeys)
        let revisedUnique = try uniqueKeyIndices(revisedKeys)
        for (offset, entry) in sourceUnique.enumerated() {
            if offset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let (key, sourceIndex) = entry
            guard !occupiedSource.contains(sourceIndex),
                  let revisedIndex = revisedUnique[key],
                  !occupiedRevised.contains(revisedIndex),
                  repeatedAnchor(
                    sourceIndex: sourceIndex,
                    revisedIndex: revisedIndex,
                    isCompatibleWith: requiredAnchors
                  )
            else { continue }
            candidates.append(
                AnchorCandidate(
                    source: sourceIndex,
                    revised: revisedIndex,
                    basis: basis
                )
            )
            occupiedSource.insert(sourceIndex)
            occupiedRevised.insert(revisedIndex)
        }
    }

    func appendRepeatedOrderAnchors(
        sourceKeys: [Data?],
        revisedKeys: [Data?],
        stableAnchors: [AnchorCandidate],
        candidates: inout [AnchorCandidate],
        occupiedSource: inout Set<Int>,
        occupiedRevised: inout Set<Int>
    ) throws {
        var sourceLowerBound = 0
        var revisedLowerBound = 0
        for boundaryIndex in 0...stableAnchors.count {
            if boundaryIndex.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            let sourceUpperBound = boundaryIndex < stableAnchors.count
                ? stableAnchors[boundaryIndex].source
                : sourceKeys.count
            let revisedUpperBound = boundaryIndex < stableAnchors.count
                ? stableAnchors[boundaryIndex].revised
                : revisedKeys.count
            let sourceRange = sourceLowerBound..<sourceUpperBound
            let revisedRange = revisedLowerBound..<revisedUpperBound
            if !sourceRange.isEmpty, !revisedRange.isEmpty {
                var sourceGroups: [Data: [Int]] = [:]
                var revisedGroups: [Data: [Int]] = [:]
                for sourceIndex in sourceRange
                where !occupiedSource.contains(sourceIndex) {
                    if sourceIndex.isMultiple(of: 64) {
                        try Task.checkCancellation()
                    }
                    guard let key = sourceKeys[sourceIndex] else {
                        continue
                    }
                    sourceGroups[key, default: []].append(sourceIndex)
                }
                for revisedIndex in revisedRange
                where !occupiedRevised.contains(revisedIndex) {
                    if revisedIndex.isMultiple(of: 64) {
                        try Task.checkCancellation()
                    }
                    guard let key = revisedKeys[revisedIndex] else {
                        continue
                    }
                    revisedGroups[key, default: []].append(revisedIndex)
                }

                let orderedSourceGroups = sourceGroups.sorted {
                    ($0.value.first ?? .max)
                        < ($1.value.first ?? .max)
                }
                for (groupIndex, entry) in
                    orderedSourceGroups.enumerated() {
                    if groupIndex.isMultiple(of: 32) {
                        try Task.checkCancellation()
                    }
                    guard let revisedIndices = revisedGroups[entry.key],
                          entry.value.count > 1
                            || revisedIndices.count > 1
                    else { continue }
                    let pairs = try repeatedOrderPairs(
                        sourceIndices: entry.value,
                        sourceRange: sourceRange,
                        revisedIndices: revisedIndices,
                        revisedRange: revisedRange
                    )
                    for pair in pairs {
                        guard !occupiedSource.contains(pair.source),
                              !occupiedRevised.contains(pair.revised)
                        else { continue }
                        candidates.append(
                            AnchorCandidate(
                                source: pair.source,
                                revised: pair.revised,
                                basis: .repeatedContent
                            )
                        )
                        occupiedSource.insert(pair.source)
                        occupiedRevised.insert(pair.revised)
                    }
                }
            }
            guard boundaryIndex < stableAnchors.count else {
                continue
            }
            sourceLowerBound = stableAnchors[boundaryIndex].source + 1
            revisedLowerBound = stableAnchors[boundaryIndex].revised + 1
        }
    }

    func repeatedOrderPairs(
        sourceIndices: [Int],
        sourceRange: Range<Int>,
        revisedIndices: [Int],
        revisedRange: Range<Int>
    ) throws -> [(source: Int, revised: Int)] {
        guard !sourceIndices.isEmpty,
              !revisedIndices.isEmpty,
              !sourceRange.isEmpty,
              !revisedRange.isEmpty
        else { return [] }
        if sourceIndices.count == revisedIndices.count {
            return Array(zip(sourceIndices, revisedIndices))
        }

        var pairs: [(source: Int, revised: Int)] = []
        pairs.reserveCapacity(
            min(sourceIndices.count, revisedIndices.count)
        )
        if sourceIndices.count < revisedIndices.count {
            var minimumRevisedOffset = 0
            for (sourceOffset, sourceIndex)
                in sourceIndices.enumerated() {
                if sourceOffset.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                let remainingSourceCount =
                    sourceIndices.count - sourceOffset - 1
                let maximumRevisedOffset =
                    revisedIndices.count - remainingSourceCount - 1
                let target = relativePosition(
                    sourceIndex,
                    in: sourceRange
                )
                let revisedOffset = nearestIndexOffset(
                    in: revisedIndices,
                    allowed: minimumRevisedOffset...maximumRevisedOffset,
                    target: target,
                    pageRange: revisedRange
                )
                pairs.append(
                    (
                        source: sourceIndex,
                        revised: revisedIndices[revisedOffset]
                    )
                )
                minimumRevisedOffset = revisedOffset + 1
            }
        } else {
            var minimumSourceOffset = 0
            for (revisedOffset, revisedIndex)
                in revisedIndices.enumerated() {
                if revisedOffset.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                let remainingRevisedCount =
                    revisedIndices.count - revisedOffset - 1
                let maximumSourceOffset =
                    sourceIndices.count - remainingRevisedCount - 1
                let target = relativePosition(
                    revisedIndex,
                    in: revisedRange
                )
                let sourceOffset = nearestIndexOffset(
                    in: sourceIndices,
                    allowed: minimumSourceOffset...maximumSourceOffset,
                    target: target,
                    pageRange: sourceRange
                )
                pairs.append(
                    (
                        source: sourceIndices[sourceOffset],
                        revised: revisedIndex
                    )
                )
                minimumSourceOffset = sourceOffset + 1
            }
        }
        return pairs
    }

    func nearestIndexOffset(
        in indices: [Int],
        allowed: ClosedRange<Int>,
        target: Double,
        pageRange: Range<Int>
    ) -> Int {
        var lower = allowed.lowerBound
        var upper = allowed.upperBound + 1
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if relativePosition(
                indices[middle],
                in: pageRange
            ) < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let upperCandidate = min(lower, allowed.upperBound)
        let lowerCandidate = max(
            allowed.lowerBound,
            upperCandidate - 1
        )
        let lowerDistance = abs(
            relativePosition(
                indices[lowerCandidate],
                in: pageRange
            ) - target
        )
        let upperDistance = abs(
            relativePosition(
                indices[upperCandidate],
                in: pageRange
            ) - target
        )
        return lowerDistance <= upperDistance
            ? lowerCandidate
            : upperCandidate
    }

    func relativePosition(
        _ index: Int,
        in range: Range<Int>
    ) -> Double {
        guard range.count > 1 else { return 0.5 }
        return min(
            1,
            max(
                0,
                Double(index - range.lowerBound)
                    / Double(range.count - 1)
            )
        )
    }

    func repeatedAnchor(
        sourceIndex: Int,
        revisedIndex: Int,
        isCompatibleWith stableAnchors: [AnchorCandidate]
    ) -> Bool {
        var lower = 0
        var upper = stableAnchors.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if stableAnchors[middle].source < sourceIndex {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let previous = lower > 0
            ? stableAnchors[lower - 1]
            : nil

        var nextIndex = lower
        while nextIndex < stableAnchors.count,
              stableAnchors[nextIndex].source == sourceIndex {
            nextIndex += 1
        }
        let next = nextIndex < stableAnchors.count
            ? stableAnchors[nextIndex]
            : nil
        if let previous,
           revisedIndex <= previous.revised {
            return false
        }
        if let next,
           revisedIndex >= next.revised {
            return false
        }
        return true
    }

    func uniqueKeyIndices(
        _ keys: [Data?]
    ) throws -> [Data: Int] {
        let grouped = try keyIndexGroups(keys)
        var result: [Data: Int] = [:]
        result.reserveCapacity(grouped.count)
        for (offset, entry) in grouped.enumerated() {
            if offset.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard entry.value.count == 1,
                  let index = entry.value.first
            else { continue }
            result[entry.key] = index
        }
        return result
    }

    func keyIndexGroups(
        _ keys: [Data?]
    ) throws -> [Data: [Int]] {
        var result: [Data: [Int]] = [:]
        for (index, key) in keys.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard let key else { continue }
            result[key, default: []].append(index)
        }
        return result
    }

    func contextualAnchorKeys(
        pages: [PageSnapshot],
        keys: [Data?]
    ) throws -> [Data?] {
        guard pages.count == keys.count else {
            return Array(repeating: nil, count: pages.count)
        }
        var groups: [(key: Data, indices: [Int])] = []
        groups.reserveCapacity(keys.count)
        for (index, key) in keys.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard let key else { continue }
            if groups.last?.key == key {
                groups[groups.count - 1].indices.append(index)
            } else {
                groups.append((key, [index]))
            }
        }
        var result = Array<Data?>(
            repeating: nil,
            count: pages.count
        )
        for groupIndex in groups.indices {
            if groupIndex.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let previous = groupIndex > 0
                ? groups[groupIndex - 1].key
                : nil
            let next = groupIndex + 1 < groups.count
                ? groups[groupIndex + 1].key
                : nil
            guard previous != nil || next != nil else { continue }
            for index in groups[groupIndex].indices {
                var material = Data([0x43])
                material.append(previous ?? Data([0x00]))
                material.append(groups[groupIndex].key)
                material.append(next ?? Data([0xFF]))
                let page = pages[index]
                var width = Int(page.pageSize.width.rounded())
                var height = Int(page.pageSize.height.rounded())
                var characters = min(
                    page.textCharacterCount / 32,
                    65_535
                )
                withUnsafeBytes(of: &width) {
                    material.append(contentsOf: $0)
                }
                withUnsafeBytes(of: &height) {
                    material.append(contentsOf: $0)
                }
                withUnsafeBytes(of: &characters) {
                    material.append(contentsOf: $0)
                }
                result[index] = Data(
                    SHA256.hash(data: material)
                )
            }
        }
        return result
    }

    func pageAnchorKey(
        _ page: PageSnapshot
    ) -> Data? {
        if page.textCharacterCount >= 8,
           !page.textFingerprint.isEmpty {
            return Data([0x54]) + page.textFingerprint
        }
        guard !page.visualSamples.isEmpty else { return nil }
        return Data([0x56])
            + Data(SHA256.hash(data: Data(page.visualSamples)))
    }

    func longestIncreasingAnchors(
        _ candidates: [AnchorCandidate]
    ) throws -> [AnchorCandidate] {
        guard !candidates.isEmpty else { return [] }
        var tails: [Int] = []
        var tailCandidateIndices: [Int] = []
        var predecessors = Array(
            repeating: -1,
            count: candidates.count
        )

        for (candidateIndex, candidate) in candidates.enumerated() {
            if candidateIndex.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            var lower = 0
            var upper = tails.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if tails[middle] < candidate.revised {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            if lower > 0 {
                predecessors[candidateIndex]
                    = tailCandidateIndices[lower - 1]
            }
            if lower == tails.count {
                tails.append(candidate.revised)
                tailCandidateIndices.append(candidateIndex)
            } else {
                tails[lower] = candidate.revised
                tailCandidateIndices[lower] = candidateIndex
            }
        }

        var result: [AnchorCandidate] = []
        var index = tailCandidateIndices.last ?? -1
        var reconstructionCount = 0
        while index >= 0 {
            if reconstructionCount.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            result.append(candidates[index])
            index = predecessors[index]
            reconstructionCount += 1
        }
        return result.reversed()
    }

    func alignSegment(
        source: [PageSnapshot],
        sourceRange: Range<Int>,
        revised: [PageSnapshot],
        revisedRange: Range<Int>
    ) throws -> [AlignedPage] {
        try Task.checkCancellation()
        let sourceIndices = Array(sourceRange)
        let revisedIndices = Array(revisedRange)
        guard !sourceIndices.isEmpty else {
            return revisedIndices.map {
                AlignedPage(
                    sourceIndex: nil,
                    revisedIndex: $0,
                    basis: nil
                )
            }
        }
        guard !revisedIndices.isEmpty else {
            return sourceIndices.map {
                AlignedPage(
                    sourceIndex: $0,
                    revisedIndex: nil,
                    basis: nil
                )
            }
        }
        let (alignmentCellCount, alignmentOverflow) =
            sourceIndices.count.multipliedReportingOverflow(
                by: revisedIndices.count
            )
        guard !alignmentOverflow,
              alignmentCellCount <= 250_000 else {
            let paired = min(
                sourceIndices.count,
                revisedIndices.count
            )
            var result = (0..<paired).map {
                AlignedPage(
                    sourceIndex: sourceIndices[$0],
                    revisedIndex: revisedIndices[$0],
                    basis: .similarity
                )
            }
            for index in sourceIndices.dropFirst(paired) {
                result.append(
                    AlignedPage(
                        sourceIndex: index,
                        revisedIndex: nil,
                        basis: nil
                    )
                )
            }
            for index in revisedIndices.dropFirst(paired) {
                result.append(
                    AlignedPage(
                        sourceIndex: nil,
                        revisedIndex: index,
                        basis: nil
                    )
                )
            }
            return result
        }

        let columns = revisedIndices.count + 1
        var scores = Array(
            repeating: Double.zero,
            count: (sourceIndices.count + 1) * columns
        )
        var directions = Array(
            repeating: UInt8.zero,
            count: scores.count
        )
        let gap = -1.5
        for row in 1...sourceIndices.count {
            if row.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            scores[row * columns] = Double(row) * gap
            directions[row * columns] = 2
        }
        for column in 1...revisedIndices.count {
            scores[column] = Double(column) * gap
            directions[column] = 3
        }

        for row in 1...sourceIndices.count {
            try Task.checkCancellation()
            for column in 1...revisedIndices.count {
                let diagonal = scores[
                    (row - 1) * columns + column - 1
                ] + pageSimilarityScore(
                    source[sourceIndices[row - 1]],
                    revised[revisedIndices[column - 1]]
                )
                let removed = scores[
                    (row - 1) * columns + column
                ] + gap
                let inserted = scores[
                    row * columns + column - 1
                ] + gap
                let offset = row * columns + column
                if diagonal >= removed && diagonal >= inserted {
                    scores[offset] = diagonal
                    directions[offset] = 1
                } else if removed >= inserted {
                    scores[offset] = removed
                    directions[offset] = 2
                } else {
                    scores[offset] = inserted
                    directions[offset] = 3
                }
            }
        }

        var result: [AlignedPage] = []
        var row = sourceIndices.count
        var column = revisedIndices.count
        var backtrackCount = 0
        while row > 0 || column > 0 {
            if backtrackCount.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            backtrackCount += 1
            let direction = directions[row * columns + column]
            if direction == 1 {
                result.append(
                    AlignedPage(
                        sourceIndex: sourceIndices[row - 1],
                        revisedIndex: revisedIndices[column - 1],
                        basis: .similarity
                    )
                )
                row -= 1
                column -= 1
            } else if direction == 2 {
                result.append(
                    AlignedPage(
                        sourceIndex: sourceIndices[row - 1],
                        revisedIndex: nil,
                        basis: nil
                    )
                )
                row -= 1
            } else {
                result.append(
                    AlignedPage(
                        sourceIndex: nil,
                        revisedIndex: revisedIndices[column - 1],
                        basis: nil
                    )
                )
                column -= 1
            }
        }
        return result.reversed()
    }

    func locatedTextDifferences(
        source: [TextFragment],
        revised: [TextFragment]
    ) -> (
        source: [PDFTextDifferenceEvidence],
        revised: [PDFTextDifferenceEvidence],
        sourceOmittedCount: Int,
        revisedOmittedCount: Int
    ) {
        guard !source.isEmpty || !revised.isEmpty else {
            return ([], [], 0, 0)
        }
        let sourceTokens = source.map(\.comparison)
        let revisedTokens = revised.map(\.comparison)
        let difference = revisedTokens.difference(from: sourceTokens)
        var removedOffsets: [Int] = []
        var insertedOffsets: [Int] = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removedOffsets.append(offset)
            case .insert(let offset, _, _):
                insertedOffsets.append(offset)
            }
        }
        let sortedRemoved = removedOffsets.sorted()
        let sortedInserted = insertedOffsets.sorted()
        var pairedRemoved: Set<Int> = []
        var pairedInserted: Set<Int> = []
        let insertedOffsetSet = Set(sortedInserted)
        var removed = BoundedTextEvidenceAccumulator(
            limit: Self.maximumLocatedTextEvidencePerSide
        )
        var inserted = BoundedTextEvidenceAccumulator(
            limit: Self.maximumLocatedTextEvidencePerSide
        )

        for (index, removedOffset) in sortedRemoved.enumerated() {
            if index.isMultiple(of: 16), Task.isCancelled {
                break
            }
            guard source.indices.contains(removedOffset) else {
                continue
            }
            let nearbyInsertedOffsets = (
                max(0, removedOffset - 3)...(removedOffset + 3)
            )
            .filter {
                insertedOffsetSet.contains($0)
                    && !pairedInserted.contains($0)
                    && revised.indices.contains($0)
            }
            .sorted {
                let lhsDistance = abs(removedOffset - $0)
                let rhsDistance = abs(removedOffset - $1)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return $0 < $1
            }
            var match: (
                offset: Int,
                refined: (
                    source: [PDFTextDifferenceEvidence],
                    revised: [PDFTextDifferenceEvidence],
                    sourceOmittedCount: Int,
                    revisedOmittedCount: Int
                )
            )?
            for insertedOffset in nearbyInsertedOffsets {
                guard !Task.isCancelled else { break }
                if let refined = refinedCharacterDifferences(
                    source: source[removedOffset],
                    revised: revised[insertedOffset]
                ) {
                    match = (insertedOffset, refined)
                    break
                }
            }
            guard let match else { continue }
            pairedRemoved.insert(removedOffset)
            pairedInserted.insert(match.offset)
            removed.append(contentsOf: match.refined.source)
            removed.addOmitted(match.refined.sourceOmittedCount)
            inserted.append(contentsOf: match.refined.revised)
            inserted.addOmitted(match.refined.revisedOmittedCount)
        }

        for (index, offset) in sortedRemoved.enumerated()
            where !pairedRemoved.contains(offset) {
            if index.isMultiple(of: 32), Task.isCancelled {
                break
            }
            guard source.indices.contains(offset) else { continue }
            let fragment = source[offset]
            removed.append(
                PDFTextDifferenceEvidence(
                    kind: .removed,
                    text: fragment.text,
                    region: fragment.region
                )
            )
        }
        for (index, offset) in sortedInserted.enumerated()
            where !pairedInserted.contains(offset) {
            if index.isMultiple(of: 32), Task.isCancelled {
                break
            }
            guard revised.indices.contains(offset) else { continue }
            let fragment = revised[offset]
            inserted.append(
                PDFTextDifferenceEvidence(
                    kind: .inserted,
                    text: fragment.text,
                    region: fragment.region
                )
            )
        }
        return (
            removed.evidence,
            inserted.evidence,
            removed.omittedCount,
            inserted.omittedCount
        )
    }

    func refinedCharacterDifferences(
        source: TextFragment,
        revised: TextFragment
    ) -> (
        source: [PDFTextDifferenceEvidence],
        revised: [PDFTextDifferenceEvidence],
        sourceOmittedCount: Int,
        revisedOmittedCount: Int
    )? {
        let sourceCharacters = source.characters
        let revisedCharacters = revised.characters
        guard !sourceCharacters.isEmpty,
              !revisedCharacters.isEmpty
        else { return nil }

        let runs = characterDifferenceRuns(
            source: sourceCharacters,
            revised: revisedCharacters
        )
        guard !runs.isEmpty else { return nil }

        var sourceEvidence = BoundedTextEvidenceAccumulator(
            limit: Self.maximumCharacterEvidencePerToken
        )
        var revisedEvidence = BoundedTextEvidenceAccumulator(
            limit: Self.maximumCharacterEvidencePerToken
        )
        for (index, run) in runs.enumerated() {
            if index.isMultiple(of: 16), Task.isCancelled {
                break
            }
            if let evidence = characterEvidence(
                run.source,
                kind: .removed
            ) {
                sourceEvidence.append(evidence)
            }
            if let evidence = characterEvidence(
                run.revised,
                kind: .inserted
            ) {
                revisedEvidence.append(evidence)
            }
        }
        guard !sourceEvidence.evidence.isEmpty
                || !revisedEvidence.evidence.isEmpty
        else {
            return nil
        }
        return (
            sourceEvidence.evidence,
            revisedEvidence.evidence,
            sourceEvidence.omittedCount,
            revisedEvidence.omittedCount
        )
    }

    func characterDifferenceRuns(
        source: [CharacterFragment],
        revised: [CharacterFragment]
    ) -> [CharacterDifferenceRun] {
        let columns = revised.count + 1
        let rows = source.count + 1
        guard rows <= Self.maximumCharacterDifferenceMatrixCells / columns
        else {
            return prefixSuffixCharacterDifferenceRuns(
                source: source,
                revised: revised
            )
        }
        let matrixCellCount = rows * columns
        var lengths = Array(
            repeating: 0,
            count: matrixCellCount
        )
        var visitedCellCount = 0
        for sourceIndex in stride(
            from: source.count - 1,
            through: 0,
            by: -1
        ) {
            for revisedIndex in stride(
                from: revised.count - 1,
                through: 0,
                by: -1
            ) {
                if visitedCellCount.isMultiple(of: 256),
                   Task.isCancelled {
                    return []
                }
                visitedCellCount += 1
                let offset = sourceIndex * columns + revisedIndex
                if source[sourceIndex].text == revised[revisedIndex].text {
                    lengths[offset] = 1
                        + lengths[(sourceIndex + 1) * columns + revisedIndex + 1]
                } else {
                    lengths[offset] = max(
                        lengths[(sourceIndex + 1) * columns + revisedIndex],
                        lengths[sourceIndex * columns + revisedIndex + 1]
                    )
                }
            }
        }

        let retainedCount = lengths[0]
        let minimumRetained = max(2, min(source.count, revised.count) / 2)
        guard retainedCount >= minimumRetained else {
            return prefixSuffixCharacterDifferenceRuns(
                source: source,
                revised: revised
            )
        }

        var sourceIndex = 0
        var revisedIndex = 0
        var pendingSource: [CharacterFragment] = []
        var pendingRevised: [CharacterFragment] = []
        var runs: [CharacterDifferenceRun] = []

        func flushPendingRun() {
            guard !pendingSource.isEmpty || !pendingRevised.isEmpty else {
                return
            }
            runs.append(
                CharacterDifferenceRun(
                    source: pendingSource,
                    revised: pendingRevised
                )
            )
            pendingSource.removeAll(keepingCapacity: true)
            pendingRevised.removeAll(keepingCapacity: true)
        }

        var backtrackCount = 0
        while sourceIndex < source.count || revisedIndex < revised.count {
            if backtrackCount.isMultiple(of: 32), Task.isCancelled {
                return []
            }
            backtrackCount += 1
            if sourceIndex < source.count,
               revisedIndex < revised.count,
               source[sourceIndex].text == revised[revisedIndex].text {
                flushPendingRun()
                sourceIndex += 1
                revisedIndex += 1
            } else if revisedIndex == revised.count
                        || sourceIndex < source.count
                            && lengths[(sourceIndex + 1) * columns + revisedIndex]
                                >= lengths[sourceIndex * columns + revisedIndex + 1] {
                pendingSource.append(source[sourceIndex])
                sourceIndex += 1
            } else {
                pendingRevised.append(revised[revisedIndex])
                revisedIndex += 1
            }
        }
        flushPendingRun()
        return runs
    }

    func prefixSuffixCharacterDifferenceRuns(
        source: [CharacterFragment],
        revised: [CharacterFragment]
    ) -> [CharacterDifferenceRun] {
        guard !source.isEmpty, !revised.isEmpty else { return [] }

        var prefixCount = 0
        while prefixCount < source.count,
              prefixCount < revised.count,
              source[prefixCount].text == revised[prefixCount].text {
            if prefixCount.isMultiple(of: 64), Task.isCancelled {
                return []
            }
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount
                < source.count - prefixCount,
              suffixCount
                < revised.count - prefixCount,
              source[source.count - suffixCount - 1].text
                == revised[revised.count - suffixCount - 1].text {
            if suffixCount.isMultiple(of: 64), Task.isCancelled {
                return []
            }
            suffixCount += 1
        }

        let sourceEnd = source.count - suffixCount
        let revisedEnd = revised.count - suffixCount
        let anchorCount = prefixCount + suffixCount
        let minimumAnchorCount = max(
            1,
            min(source.count, revised.count) / 3
        )
        guard anchorCount >= minimumAnchorCount else { return [] }

        let sourceChanged = Array(
            source[prefixCount..<sourceEnd]
        )
        let revisedChanged = Array(
            revised[prefixCount..<revisedEnd]
        )
        guard !sourceChanged.isEmpty || !revisedChanged.isEmpty else {
            return []
        }
        return [
            CharacterDifferenceRun(
                source: sourceChanged,
                revised: revisedChanged
            )
        ]
    }

    func characterEvidence(
        _ fragments: [CharacterFragment],
        kind: PDFTextDifferenceKind
    ) -> PDFTextDifferenceEvidence? {
        guard let first = fragments.first else { return nil }
        let region = fragments.dropFirst().reduce(first.region) {
            union($0, $1.region)
        }
        return PDFTextDifferenceEvidence(
            kind: kind,
            text: fragments.map(\.text).joined(),
            region: region,
            granularity: .character
        )
    }

    func union(
        _ lhs: PDFDifferenceRegion,
        _ rhs: PDFDifferenceRegion
    ) -> PDFDifferenceRegion {
        let minX = min(lhs.x, rhs.x)
        let minY = min(lhs.y, rhs.y)
        let maxX = max(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = max(lhs.y + lhs.height, rhs.y + rhs.height)
        return PDFDifferenceRegion(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY),
            intensity: max(lhs.intensity, rhs.intensity)
        )
    }

    func locatedVectorDifferences(
        source: [PDFVectorFragment]?,
        revised: [PDFVectorFragment]?,
        visualRegions: [PDFDifferenceRegion]
    ) -> (
        source: [PDFVectorDifferenceEvidence],
        revised: [PDFVectorDifferenceEvidence]
    ) {
        guard let source,
              let revised,
              !source.isEmpty || !revised.isEmpty,
              !visualRegions.isEmpty
        else { return ([], []) }

        var remainingRevisedCounts: [Data: Int] = [:]
        for fragment in revised {
            remainingRevisedCounts[
                fragment.fingerprint,
                default: 0
            ] += 1
        }
        var unmatchedSource: [PDFVectorFragment] = []
        unmatchedSource.reserveCapacity(min(source.count, 24))
        for fragment in source {
            let count = remainingRevisedCounts[
                fragment.fingerprint,
                default: 0
            ]
            if count > 0 {
                remainingRevisedCounts[fragment.fingerprint] =
                    count - 1
            } else {
                unmatchedSource.append(fragment)
            }
        }

        var unmatchedRevised: [PDFVectorFragment] = []
        unmatchedRevised.reserveCapacity(min(revised.count, 24))
        for fragment in revised {
            let count = remainingRevisedCounts[
                fragment.fingerprint,
                default: 0
            ]
            guard count > 0 else { continue }
            unmatchedRevised.append(fragment)
            remainingRevisedCounts[fragment.fingerprint] =
                count - 1
        }

        let sourceEvidence = unmatchedSource.lazy
            .filter {
                intersectsVisualEvidence(
                    $0.region,
                    regions: visualRegions
                )
            }
            .prefix(24)
            .map {
                PDFVectorDifferenceEvidence(
                    kind: .removed,
                    region: $0.region
                )
            }
        let revisedEvidence = unmatchedRevised.lazy
            .filter {
                intersectsVisualEvidence(
                    $0.region,
                    regions: visualRegions
                )
            }
            .prefix(24)
            .map {
                PDFVectorDifferenceEvidence(
                    kind: .inserted,
                    region: $0.region
                )
            }
        return (Array(sourceEvidence), Array(revisedEvidence))
    }

    func intersectsVisualEvidence(
        _ region: PDFDifferenceRegion,
        regions: [PDFDifferenceRegion]
    ) -> Bool {
        let margin = 0.012
        return regions.contains { visual in
            let visualMinX = max(0, visual.x - margin)
            let visualMinY = max(0, visual.y - margin)
            let visualMaxX = min(
                1,
                visual.x + visual.width + margin
            )
            let visualMaxY = min(
                1,
                visual.y + visual.height + margin
            )
            return region.x < visualMaxX
                && region.x + region.width > visualMinX
                && region.y < visualMaxY
                && region.y + region.height > visualMinY
        }
    }

    func pageSimilarityScore(
        _ source: PageSnapshot,
        _ revised: PageSnapshot
    ) -> Double {
        if source.textCharacterCount >= 8,
           source.textFingerprint == revised.textFingerprint {
            return 6
        }
        let visual = visualDifference(
            source.alignmentSamples,
            revised.alignmentSamples,
            channels: 1
        )
        if visual.changedPixelRatio <= 0.002,
           !pageGeometryChanged(source, revised) {
            return 5
        }
        if visual.changedPixelRatio <= 0.03 {
            return 2.5
        }
        let maximumCharacters = max(
            source.textCharacterCount,
            revised.textCharacterCount
        )
        if maximumCharacters > 0,
           Double(
               abs(
                   source.textCharacterCount
                    - revised.textCharacterCount
               )
           ) / Double(maximumCharacters) <= 0.12 {
            return 1
        }
        return -2
    }

    func detailedVisualDifference(
        _ source: [UInt8],
        _ revised: [UInt8]
    ) -> DetailedVisualDifference {
        let channels = 3
        let pixelCount = source.count / channels
        let side = Int(Double(pixelCount).squareRoot())
        guard side >= 6,
              side.isMultiple(of: 6),
              side * side == pixelCount,
              source.count == side * side * channels,
              revised.count == source.count
        else {
            return DetailedVisualDifference(
                meanDifference: 1,
                changedPixelRatio: 1,
                regions: nil
            )
        }
        let grid = 6
        let cellSide = side / grid
        var regions: [PDFDifferenceRegion] = []
        var totalDifference = 0
        var totalChangedPixels = 0
        for row in 0..<grid {
            for column in 0..<grid {
                var total = 0
                var changed = 0
                for y in (row * cellSide)..<((row + 1) * cellSide) {
                    for x in (column * cellSide)..<((column + 1) * cellSide) {
                        let offset = (y * side + x) * channels
                        let delta = max(
                            abs(Int(source[offset]) - Int(revised[offset])),
                            abs(
                                Int(source[offset + 1])
                                    - Int(revised[offset + 1])
                            ),
                            abs(
                                Int(source[offset + 2])
                                    - Int(revised[offset + 2])
                            )
                        )
                        total += delta
                        totalDifference +=
                            abs(
                                Int(source[offset])
                                    - Int(revised[offset])
                            )
                            + abs(
                                Int(source[offset + 1])
                                    - Int(revised[offset + 1])
                            )
                            + abs(
                                Int(source[offset + 2])
                                    - Int(revised[offset + 2])
                            )
                        if delta >= 8 {
                            changed += 1
                            totalChangedPixels += 1
                        }
                    }
                }
                let pixels = cellSide * cellSide
                let ratio = Double(changed) / Double(pixels)
                let mean = Double(total) / Double(pixels * 255)
                guard ratio >= 0.08 || mean >= 0.025 else {
                    continue
                }
                regions.append(
                    PDFDifferenceRegion(
                        x: Double(column) / Double(grid),
                        y: Double(row) / Double(grid),
                        width: 1 / Double(grid),
                        height: 1 / Double(grid),
                        intensity: min(1, max(ratio, mean * 4))
                    )
                )
            }
        }
        return DetailedVisualDifference(
            meanDifference:
                Double(totalDifference)
                / Double(pixelCount * 255 * channels),
            changedPixelRatio:
                Double(totalChangedPixels) / Double(pixelCount),
            regions: Array(
                regions.sorted {
                    $0.intensity > $1.intensity
                }.prefix(12)
            )
        )
    }

    func pageGeometryChanged(
        _ source: PageSnapshot,
        _ revised: PageSnapshot
    ) -> Bool {
        let sourceRotation = ((source.rotation % 360) + 360) % 360
        let revisedRotation = ((revised.rotation % 360) + 360) % 360
        guard sourceRotation == revisedRotation else { return true }
        let widthScale = max(source.pageSize.width, revised.pageSize.width)
        let heightScale = max(source.pageSize.height, revised.pageSize.height)
        guard widthScale > 0, heightScale > 0 else { return true }
        return abs(source.pageSize.width - revised.pageSize.width)
                / widthScale > 0.005
            || abs(source.pageSize.height - revised.pageSize.height)
                / heightScale > 0.005
    }

    func visualDifference(
        _ source: [UInt8],
        _ revised: [UInt8],
        channels: Int = 3
    ) -> (
        meanDifference: Double,
        changedPixelRatio: Double
    ) {
        guard source.count == revised.count,
              !source.isEmpty,
              channels > 0,
              source.count.isMultiple(of: channels)
        else {
            return (1, 1)
        }
        var totalDifference = 0
        var changedPixels = 0
        let pixelCount = source.count / channels
        for offset in stride(
            from: 0,
            to: source.count,
            by: channels
        ) {
            var maximumDifference = 0
            for channel in 0..<channels {
                let difference = abs(
                    Int(source[offset + channel])
                        - Int(revised[offset + channel])
                )
                totalDifference += difference
                maximumDifference = max(
                    maximumDifference,
                    difference
                )
            }
            if maximumDifference >= 8 {
                changedPixels += 1
            }
        }
        return (
            Double(totalDifference)
                / Double(pixelCount * 255 * channels),
            Double(changedPixels) / Double(pixelCount)
        )
    }

    func changeReviewCheck(
        _ review: PDFChangeReview,
        operation: PDFDeliveryOperation
    ) -> PDFDeliveryCheck {
        if operation == .bookletPrepared {
            return PDFDeliveryCheck(
                id: "visible-change-review",
                title: "Booklet imposition",
                detail: AppLocalization.format(
                    "%lld source pages reordered across %lld imposed sides",
                    review.sourcePageCount,
                    review.revisedPageCount
                ),
                status: .passed
            )
        }
        if review.geometryChangedPageCount > 0 {
            if operation == .printPrepared {
                return PDFDeliveryCheck(
                    id: "visible-change-review",
                    title: "Print geometry",
                    detail: AppLocalization.format(
                        "%lld pages standardized for printing",
                        review.geometryChangedPageCount
                    ),
                    status: .passed
                )
            }
            return PDFDeliveryCheck(
                id: "visible-change-review",
                title: "Visible change review",
                detail: pageList(
                    review.geometryChanges.map(\.pageIndex)
                ),
                status: .failed
            )
        }
        let expected: Bool
        switch operation {
        case .compressed, .redacted, .edited, .textReplaced,
             .printPrepared, .bookletPrepared:
            expected = true
        case .protected, .unlocked, .flattened, .safeShare:
            expected = false
        }
        let relevantChanges = expected
            ? review.visibleChanges
            : review.majorVisibleChanges
        guard !relevantChanges.isEmpty else {
            return PDFDeliveryCheck(
                id: "visible-change-review",
                title: "Visible change review",
                detail: "Every page matches the working copy visually",
                status: .passed
            )
        }
        return PDFDeliveryCheck(
            id: "visible-change-review",
            title: "Visible change review",
            detail: pageList(
                relevantChanges.map(\.pageIndex)
            ),
            status: expected ? .passed : .warning
        )
    }

    private struct AuditedFileIdentity {
        let byteCount: Int64
        let modificationDate: Date?
        let resourceIdentifier: Any?
    }

    private static func requireSupportedPageCount(
        _ pageCount: Int
    ) throws {
        guard pageCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        guard pageCount <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Audit PDFs with up to 100,000 pages."
            )
        }
    }

    private func auditedFileIdentity(
        at url: URL,
        role: String
    ) throws -> AuditedFileIdentity {
        let values = try url.resourceValues(
            forKeys: [
                .contentModificationDateKey,
                .fileResourceIdentifierKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0
        else {
            if role == "output" {
                throw PaperPathError.outputVerificationFailed(
                    "the output PDF is not a regular file"
                )
            }
            throw PaperPathError.unreadablePDF
        }
        guard Int64(fileSize) <= Self.maximumFileBytes else {
            throw PaperPathError.fileTooLarge
        }
        return AuditedFileIdentity(
            byteCount: Int64(fileSize),
            modificationDate: values.contentModificationDate,
            resourceIdentifier: values.fileResourceIdentifier
        )
    }

    private func requireUnchangedFile(
        at url: URL,
        expected: AuditedFileIdentity,
        role: String
    ) throws {
        try Task.checkCancellation()
        let current = try auditedFileIdentity(at: url, role: role)
        guard current.byteCount == expected.byteCount,
              current.modificationDate == expected.modificationDate,
              Self.fileResourceIdentifiersMatch(
                current.resourceIdentifier,
                expected.resourceIdentifier
              )
        else {
            throw PaperPathError.outputVerificationFailed(
                "the \(role) PDF changed while its evidence was being collected"
            )
        }
    }

    private static func fileResourceIdentifiersMatch(
        _ first: Any?,
        _ second: Any?
    ) -> Bool {
        switch (first, second) {
        case (nil, nil):
            return true
        case let (first as NSObject, second):
            return first.isEqual(second)
        default:
            return false
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map {
            String(format: "%02x", $0)
        }
        .joined()
    }

    private func check(
        id: String,
        title: String,
        passed: Bool,
        passDetail: String,
        failDetail: String
    ) -> PDFDeliveryCheck {
        PDFDeliveryCheck(
            id: id,
            title: title,
            detail: passed ? passDetail : failDetail,
            status: passed ? .passed : .failed
        )
    }

    func pageList(_ zeroBasedPages: [Int]) -> String {
        let values = zeroBasedPages
            .prefix(8)
            .map { String($0 + 1) }
            .joined(separator: ", ")
        return "Review page\(zeroBasedPages.count == 1 ? "" : "s") \(values)"
    }

    private func fittedSize(
        _ size: CGSize,
        longestEdge: CGFloat
    ) -> CGSize {
        let edge = max(size.width, size.height)
        guard edge > 0 else {
            return CGSize(width: longestEdge, height: longestEdge)
        }
        let scale = longestEdge / edge
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }

    struct SnapshotOptions {
        static let complete = SnapshotOptions(
            renderedPageIndices: nil,
            renderLongestEdge: 160,
            maximumTextFragments: 160,
            detailedTextPageStride: 1,
            maximumVectorFragments: 192,
            detailedVectorPageStride: 1,
            visualSampleSide: 48,
            detectBarcodes: false
        )

        let renderedPageIndices: Set<Int>?
        let renderLongestEdge: CGFloat
        let maximumTextFragments: Int
        let detailedTextPageStride: Int
        let maximumVectorFragments: Int
        let detailedVectorPageStride: Int
        let visualSampleSide: Int
        let detectBarcodes: Bool

        static func preflight(pageCount: Int) -> SnapshotOptions {
            let maximumRenderedPages = 24
            guard pageCount > maximumRenderedPages else {
                return SnapshotOptions(
                    renderedPageIndices: nil,
                    renderLongestEdge: 160,
                    maximumTextFragments: 0,
                    detailedTextPageStride: 1,
                    maximumVectorFragments: 0,
                    detailedVectorPageStride: 1,
                    visualSampleSide: 48,
                    detectBarcodes: false
                )
            }
            let lastPage = max(0, pageCount - 1)
            let indices = Set(
                (0..<maximumRenderedPages).map { position in
                    guard maximumRenderedPages > 1 else { return 0 }
                    return Int(
                        (
                            Double(position)
                                / Double(maximumRenderedPages - 1)
                                * Double(lastPage)
                        ).rounded()
                    )
                }
            )
            return SnapshotOptions(
                renderedPageIndices: indices,
                renderLongestEdge: 128,
                maximumTextFragments: 0,
                detailedTextPageStride: 1,
                maximumVectorFragments: 0,
                detailedVectorPageStride: 1,
                visualSampleSide: 48,
                detectBarcodes: false
            )
        }

        static func comparison(pageCount: Int) -> SnapshotOptions {
            let maximumTextFragments: Int
            let visualSampleSide: Int
            if pageCount > 10_000 {
                maximumTextFragments = 80
                visualSampleSide = 6
            } else if pageCount > 2_000 {
                maximumTextFragments = 80
                visualSampleSide = 12
            } else if pageCount > 600 {
                maximumTextFragments = 80
                visualSampleSide = 24
            } else if pageCount > 300 {
                maximumTextFragments = 80
                visualSampleSide = 36
            } else if pageCount > 120 {
                maximumTextFragments = 160
                visualSampleSide = 48
            } else {
                maximumTextFragments = 320
                visualSampleSide = 48
            }
            let maximumDetailedTextPages = max(
                1,
                48_000 / maximumTextFragments
            )
            let textStride = max(
                1,
                Int(
                    ceil(
                        Double(max(1, pageCount))
                            / Double(maximumDetailedTextPages)
                    )
                )
            )
            let maximumVectorFragments: Int
            if pageCount > 2_000 {
                maximumVectorFragments = 48
            } else if pageCount > 600 {
                maximumVectorFragments = 96
            } else {
                maximumVectorFragments = 192
            }
            let maximumDetailedVectorPages = max(
                1,
                24_000 / maximumVectorFragments
            )
            let vectorStride = max(
                1,
                Int(
                    ceil(
                        Double(max(1, pageCount))
                            / Double(maximumDetailedVectorPages)
                    )
                )
            )
            return SnapshotOptions(
                renderedPageIndices: nil,
                renderLongestEdge: pageCount > 300
                    ? 96
                    : pageCount > 120
                        ? 128
                        : 160,
                maximumTextFragments: maximumTextFragments,
                detailedTextPageStride: textStride,
                maximumVectorFragments: maximumVectorFragments,
                detailedVectorPageStride: vectorStride,
                visualSampleSide: visualSampleSide,
                detectBarcodes: pageCount <= 200
            )
        }

        func shouldRender(pageIndex: Int) -> Bool {
            renderedPageIndices?.contains(pageIndex) ?? true
        }

        func shouldCaptureTextFragments(
            pageIndex: Int,
            pageCount: Int
        ) -> Bool {
            maximumTextFragments > 0
                && (
                    pageIndex.isMultiple(
                        of: max(1, detailedTextPageStride)
                    )
                        || pageIndex == max(0, pageCount - 1)
                )
        }

        func shouldCaptureVectorFragments(
            pageIndex: Int,
            pageCount: Int
        ) -> Bool {
            maximumVectorFragments > 0
                && (
                    pageIndex.isMultiple(
                        of: max(1, detailedVectorPageStride)
                    )
                        || pageIndex == max(0, pageCount - 1)
                )
        }
    }

    struct Snapshot {
        let pageCount: Int
        let renderedPageCount: Int
        let renderAttemptedPageCount: Int
        let renderedPageIndices: [Int]
        let contentCoverage: [Double]
        let annotationCount: Int
        let textCharacterCount: Int
        let personalMetadataEntryCount: Int
        let pages: [PageSnapshot]
    }

    struct PageSnapshot {
        let rendered: Bool
        let coverage: Double
        let annotationCount: Int
        let textCharacterCount: Int
        let textFingerprint: Data
        let textFragments: [TextFragment]
        let pageLabelFingerprint: Data?
        let stableMarkerFingerprint: Data?
        let barcodeFingerprint: Data?
        let pageSize: CGSize
        let rotation: Int
        let vectorFragments: [PDFVectorFragment]?
        let visualSamples: [UInt8]
        let alignmentSamples: [UInt8]

        init(
            rendered: Bool,
            coverage: Double,
            annotationCount: Int,
            textCharacterCount: Int,
            textFingerprint: Data,
            textFragments: [TextFragment],
            pageLabelFingerprint: Data?,
            stableMarkerFingerprint: Data?,
            barcodeFingerprint: Data?,
            pageSize: CGSize,
            rotation: Int,
            vectorFragments: [PDFVectorFragment]? = nil,
            visualSamples: [UInt8],
            alignmentSamples: [UInt8]
        ) {
            self.rendered = rendered
            self.coverage = coverage
            self.annotationCount = annotationCount
            self.textCharacterCount = textCharacterCount
            self.textFingerprint = textFingerprint
            self.textFragments = textFragments
            self.pageLabelFingerprint = pageLabelFingerprint
            self.stableMarkerFingerprint = stableMarkerFingerprint
            self.barcodeFingerprint = barcodeFingerprint
            self.pageSize = pageSize
            self.rotation = rotation
            self.vectorFragments = vectorFragments
            self.visualSamples = visualSamples
            self.alignmentSamples = alignmentSamples
        }

        static let empty = PageSnapshot(
            rendered: false,
            coverage: 0,
            annotationCount: 0,
            textCharacterCount: 0,
            textFingerprint: Data(),
            textFragments: [],
            pageLabelFingerprint: nil,
            stableMarkerFingerprint: nil,
            barcodeFingerprint: nil,
            pageSize: .zero,
            rotation: 0,
            vectorFragments: nil,
            visualSamples: [],
            alignmentSamples: []
        )
    }

    private struct VisualSignature {
        let coverage: Double
        let samples: [UInt8]
        let alignmentSamples: [UInt8]
    }

    struct DetailedVisualDifference {
        let meanDifference: Double
        let changedPixelRatio: Double
        let regions: [PDFDifferenceRegion]?
    }

    struct TextFragment {
        let text: String
        let normalized: String
        let comparison: String
        let region: PDFDifferenceRegion
        let characters: [CharacterFragment]
    }

    struct CharacterFragment {
        let text: String
        let region: PDFDifferenceRegion
    }

    struct CharacterDifferenceRun {
        let source: [CharacterFragment]
        let revised: [CharacterFragment]
    }

    private struct BoundedTextEvidenceAccumulator {
        let limit: Int
        private(set) var evidence: [PDFTextDifferenceEvidence] = []
        private(set) var omittedCount = 0

        init(limit: Int) {
            self.limit = max(0, limit)
            evidence.reserveCapacity(max(0, limit))
        }

        mutating func append(_ item: PDFTextDifferenceEvidence) {
            guard evidence.count < limit else {
                addOmitted(1)
                return
            }
            evidence.append(item)
        }

        mutating func append(
            contentsOf items: [PDFTextDifferenceEvidence]
        ) {
            for item in items {
                append(item)
            }
        }

        mutating func addOmitted(_ count: Int) {
            guard count > 0 else { return }
            let (total, overflow) = omittedCount
                .addingReportingOverflow(count)
            omittedCount = overflow ? .max : total
        }
    }

    struct AnchorCandidate {
        let source: Int
        let revised: Int
        let basis: PDFPageMatchBasis
    }

    struct AlignedPage {
        let sourceIndex: Int?
        let revisedIndex: Int?
        let basis: PDFPageMatchBasis?
    }
}

struct PDFChangeReportDescriptor: Sendable {
    let reportID: UUID
    let scope: String
    let sourceName: String
    let revisedName: String
    let sourceRevisionID: UUID?
    let revisedRevisionID: UUID?
    let sourceFingerprint: String?
    let revisedFingerprint: String?
    let deliveryReceiptID: UUID?
    let generatedAt: Date
}

struct PDFChangeReportService: Sendable {
    private static let maximumReportedChanges = 1_000
    private static let maximumEvidencePerSide = 3
    private static let maximumEvidenceCharacters = 160
    private static let maximumReportBytes = 4 * 1_024 * 1_024
    private static let maximumSignedReportBytes = 5 * 1_024 * 1_024
    private static let minimumFreeSpaceReserve: Int64 = 8 * 1_024 * 1_024
    private static let signatureMarker =
        "\n<!-- PAPERPATH_CHANGE_REPORT_SIGNATURE_V1\n"
    private static let signatureSuffix = "\n-->\n"

    struct ParsedSignedReport: Sendable {
        let body: Data
        let envelope: PDFSignedChangeReportEnvelope
    }

    func render(
        review: PDFChangeReview,
        descriptor: PDFChangeReportDescriptor,
        signerKeyID: String
    ) throws -> Data {
        let markdown = try makeMarkdown(
            review: review,
            descriptor: descriptor,
            signerKeyID: signerKeyID
        )
        guard let data = markdown.data(using: .utf8),
              !data.isEmpty,
              data.count <= Self.maximumReportBytes
        else {
            throw PaperPathError.storageFailure(
                "The change report exceeded its 4 MB safety limit."
            )
        }
        return data
    }

    func signaturePayload(
        body: Data,
        review: PDFChangeReview,
        descriptor: PDFChangeReportDescriptor
    ) throws -> PDFChangeReportSignaturePayload {
        try Task.checkCancellation()
        guard !body.isEmpty,
              body.count <= Self.maximumReportBytes
        else {
            throw PaperPathError.storageFailure(
                "The change report exceeded its 4 MB safety limit."
            )
        }
        return PDFChangeReportSignaturePayload(
            schema: PDFChangeReportSignaturePayload.schema,
            reportID: descriptor.reportID,
            generatedAt: descriptor.generatedAt,
            sourceName: metadataText(descriptor.sourceName),
            revisedName: metadataText(descriptor.revisedName),
            sourceRevisionID: descriptor.sourceRevisionID,
            revisedRevisionID: descriptor.revisedRevisionID,
            sourceFingerprint: normalizedFingerprint(
                descriptor.sourceFingerprint
            ),
            revisedFingerprint: normalizedFingerprint(
                descriptor.revisedFingerprint
            ),
            deliveryReceiptID: descriptor.deliveryReceiptID,
            changedPageCount: review.totalChangedPageCount,
            bodyByteCount: body.count,
            bodySHA256: sha256(body)
        )
    }

    func create(
        body: Data,
        envelope: PDFSignedChangeReportEnvelope,
        directory: URL,
        fileName: String,
        referenceDate: Date =
            PDFOfficeTimeAnchor.process.trustedDate(),
        fileManager: FileManager = .default
    ) throws -> URL {
        try Task.checkCancellation()
        guard PaperPathTemporaryArtifact.managedTopLevelItem(
            containing: directory,
            allowedPrefixes: ["PaperPath-ChangeReport-"],
            fileManager: fileManager
        ) == directory
            .resolvingSymlinksInPath()
            .standardizedFileURL,
              !fileName.isEmpty,
              !fileName.hasPrefix("."),
              !fileName.contains("/"),
              !fileName.contains("\\"),
              fileName.lowercased().hasSuffix(".md")
        else {
            throw PaperPathError.storageFailure(
                "The change report destination is invalid."
            )
        }
        guard envelope.payload.isStructurallyValid(
                at: referenceDate
              ),
              envelope.payload.bodyByteCount == body.count,
              envelope.payload.bodySHA256.caseInsensitiveCompare(
                sha256(body)
              ) == .orderedSame,
              bodyIdentityMatches(
                  body,
                  payload: envelope.payload,
                  signerKeyID: envelope.signature.keyID
              ),
              envelope.signature.algorithm == "Ed25519",
              let publicKeyData = Data(
                base64Encoded: envelope.signature.publicKeyBase64
              ),
              let signatureData = Data(
                base64Encoded: envelope.signature.signatureBase64
              ),
              keyID(publicKeyData) == envelope.signature.keyID,
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
              ),
              let payloadData = try? Self.canonicalData(
                envelope.payload
              ),
              publicKey.isValidSignature(
                signatureData,
                for: payloadData
              ),
              let envelopeData = try? Self.canonicalData(envelope)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the change report signing envelope is invalid"
            )
        }
        var data = body
        data.append(Data(Self.signatureMarker.utf8))
        data.append(
            Data(envelopeData.base64EncodedString().utf8)
        )
        data.append(Data(Self.signatureSuffix.utf8))
        guard data.count <= Self.maximumSignedReportBytes else {
            throw PaperPathError.storageFailure(
                "The signed change report exceeded its 5 MB safety limit."
            )
        }
        if let capacity = try? directory
            .deletingLastPathComponent()
            .resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            .volumeAvailableCapacityForImportantUsage,
           capacity < Int64(data.count) + Self.minimumFreeSpaceReserve {
            throw PaperPathError.insufficientStorage
        }

        let destination = directory.appendingPathComponent(fileName)
        do {
            try LocalFileSecurity.prepareProtectedDirectory(
                at: directory,
                fileManager: fileManager
            )
            try Task.checkCancellation()
            try data.write(to: destination, options: .atomic)
            try LocalFileSecurity.requireCompleteProtection(
                to: destination,
                fileManager: fileManager
            )
            LocalFileSecurity.excludeFromBackup(destination)
            let values = try destination.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize == data.count
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the change report could not be reopened intact"
                )
            }
            try Task.checkCancellation()
            return destination
        } catch {
            PaperPathTemporaryArtifact.removeManagedItem(
                containing: directory,
                allowedPrefixes: ["PaperPath-ChangeReport-"],
                fileManager: fileManager
            )
            throw error
        }
    }

    func parseSignedReport(
        _ data: Data
    ) throws -> ParsedSignedReport {
        try Task.checkCancellation()
        guard !data.isEmpty,
              data.count <= Self.maximumSignedReportBytes
        else {
            throw PaperPathError.insufficientSelection(
                "Choose a signed PaperPath change report under 5 MB."
            )
        }
        let marker = Data(Self.signatureMarker.utf8)
        let suffix = Data(Self.signatureSuffix.utf8)
        guard data.count > marker.count + suffix.count,
              data.suffix(suffix.count) == suffix,
              let markerRange = data.range(
                of: marker,
                options: .backwards
              )
        else {
            throw PaperPathError.insufficientSelection(
                "This Markdown file is not a signed PaperPath change report."
            )
        }
        let envelopeEnd = data.count - suffix.count
        guard markerRange.upperBound < envelopeEnd else {
            throw PaperPathError.insufficientSelection(
                "This Markdown file has an empty signature envelope."
            )
        }
        let body = Data(data[..<markerRange.lowerBound])
        let encodedEnvelopeData = Data(
            data[markerRange.upperBound..<envelopeEnd]
        )
        guard let encodedEnvelope = String(
            data: encodedEnvelopeData,
            encoding: .utf8
        ),
              let envelopeData = Data(
                  base64Encoded: encodedEnvelope
              ),
              envelopeData.count <= 64 * 1_024,
              let envelope = try? canonicalDecoder().decode(
            PDFSignedChangeReportEnvelope.self,
            from: envelopeData
        ) else {
            throw PaperPathError.insufficientSelection(
                "The change report signature envelope is unreadable."
            )
        }
        return ParsedSignedReport(
            body: body,
            envelope: envelope
        )
    }

    static func canonicalData<T: Encodable>(
        _ value: T
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    func bodyIdentityMatches(
        _ body: Data,
        payload: PDFChangeReportSignaturePayload,
        signerKeyID: String
    ) -> Bool {
        guard let markdown = String(data: body, encoding: .utf8)
        else { return false }
        let lines = markdown.components(separatedBy: "\n")
        guard lines.count >= 27,
              lines[0] == "# PaperPath Change Report",
              lines[2] == "Schema: PaperPath Change Report v1",
              lines[3]
                == "Report ID: \(payload.reportID.uuidString)",
              lines[4]
                == "Generated: \(timestamp(payload.generatedAt))",
              lines[8] == "## Compared Files",
              lines[10]
                == "- Base: \(markdownInline(payload.sourceName))",
              lines[11]
                == "- Revised: \(markdownInline(payload.revisedName))",
              lines[16] == "## Evidence Identity",
              lines[18]
                == "- Base revision: \(identifier(payload.sourceRevisionID))",
              lines[19]
                == "- Revised revision: \(identifier(payload.revisedRevisionID))",
              lines[20]
                == "- Base SHA-256: \(fingerprint(payload.sourceFingerprint))",
              lines[21]
                == "- Revised SHA-256: \(fingerprint(payload.revisedFingerprint))",
              lines[22] == "- Signer Key ID: \(signerKeyID)"
        else { return false }
        let summaryIndex: Int
        if let receiptID = payload.deliveryReceiptID {
            guard lines.count >= 28,
                  lines[23]
                    == "- Delivery Receipt: \(receiptID.uuidString)"
            else { return false }
            summaryIndex = 25
        } else {
            summaryIndex = 24
        }
        return lines[summaryIndex] == "## Summary"
            && lines[summaryIndex + 2]
                == "- Changed pages: \(payload.changedPageCount)"
    }

    private func canonicalDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeMarkdown(
        review: PDFChangeReview,
        descriptor: PDFChangeReportDescriptor,
        signerKeyID: String
    ) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime
        ]
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        let sourceName = metadataText(descriptor.sourceName)
        let revisedName = metadataText(descriptor.revisedName)
        var lines = [
            "# PaperPath Change Report",
            "",
            "Schema: PaperPath Change Report v1",
            "Report ID: \(descriptor.reportID.uuidString)",
            "Generated: \(formatter.string(from: descriptor.generatedAt))",
            "App: PaperPath \(markdownInline(version)) (\(markdownInline(build)))",
            "Scope: \(markdownInline(descriptor.scope))",
            "",
            "## Compared Files",
            "",
            "- Base: \(markdownInline(sourceName))",
            "- Revised: \(markdownInline(revisedName))",
            "- Base pages: \(review.sourcePageCount)",
            "- Revised pages: \(review.revisedPageCount)",
            "- Compared pages: \(review.comparedPageCount)",
            "",
            "## Evidence Identity",
            "",
            "- Base revision: \(identifier(descriptor.sourceRevisionID))",
            "- Revised revision: \(identifier(descriptor.revisedRevisionID))",
            "- Base SHA-256: \(fingerprint(descriptor.sourceFingerprint))",
            "- Revised SHA-256: \(fingerprint(descriptor.revisedFingerprint))",
            "- Signer Key ID: \(signerKeyID)"
        ]
        if let receiptID = descriptor.deliveryReceiptID {
            lines.append("- Delivery Receipt: \(receiptID.uuidString)")
        }
        lines.append(contentsOf: [
            "",
            "## Summary",
            "",
            "- Changed pages: \(review.totalChangedPageCount)",
            "- Visible changes: \(review.visibleChangedPageCount)",
            "- Text changes: \(review.textChangedPageCount)",
            "- Vector-object changes: \(review.vectorChangedPageCount)",
            "- Vector boundaries: \(review.totalVectorDifferenceCount)",
            "- Geometry changes: \(review.geometryChangedPageCount)",
            "- Inserted pages: \(review.insertedPages.count)",
            "- Removed pages: \(review.removedPages.count)",
            "- Critical changes: \(review.criticalChanges.count)",
            "- Stable page matches: \(review.stablePageMatchCount)",
            "- Manual page matches: \(review.manualPageMatchCount)",
            "- Repeated-template matches: \(review.repeatedTemplateMatchCount)",
            "- Visual-similarity fallbacks: \(review.similarityPageMatchCount)",
            ""
        ])
        if review.manualPageMatchCount > 0,
           review.manualPageMatchPersistence != nil {
            lines.insert(
                "- Manual pairing retention: on-device correction applied; only document identifiers, revision identifiers, and page numbers are retained",
                at: max(0, lines.count - 1)
            )
        }

        if review.changes.isEmpty {
            lines.append("No page changes were detected.")
        } else {
            lines.append("## Page Changes")
            lines.append("")
            let orderedChanges = review.changes.sorted {
                let lhsSource = $0.resolvedSourcePageIndex ?? Int.max
                let rhsSource = $1.resolvedSourcePageIndex ?? Int.max
                if lhsSource != rhsSource {
                    return lhsSource < rhsSource
                }
                let lhsRevised = $0.resolvedRevisedPageIndex ?? Int.max
                let rhsRevised = $1.resolvedRevisedPageIndex ?? Int.max
                if lhsRevised != rhsRevised {
                    return lhsRevised < rhsRevised
                }
                return $0.id < $1.id
            }
            for change in orderedChanges.prefix(
                Self.maximumReportedChanges
            ) {
                try Task.checkCancellation()
                lines.append(
                    "### \(pagePairLabel(change))"
                )
                lines.append("")
                lines.append(
                    "- Type: \(change.resolvedMatchKind.title)"
                )
                lines.append("- Severity: \(change.severity.title)")
                if let basis = change.matchBasis {
                    lines.append("- Matched by: \(basis.title)")
                }
                lines.append(
                    "- Visible difference: \(percent(change.visibleDifference))"
                )
                lines.append(
                    "- Changed pixels: \(percent(change.changedPixelRatio))"
                )
                lines.append(
                    "- Page geometry changed: \(change.geometryChanged ? "Yes" : "No")"
                )
                lines.append(
                    "- Text characters: \(change.sourceTextCharacterCount) -> \(change.revisedTextCharacterCount)"
                )
                if change.hasLocatedVectorDifferences {
                    lines.append(
                        "- Vector boundaries: \(change.sourceVectorDifferences?.count ?? 0) removed, \(change.revisedVectorDifferences?.count ?? 0) added"
                    )
                }
                appendEvidence(
                    change.sourceTextDifferences,
                    label: "Removed",
                    serviceOmittedCount:
                        change
                            .resolvedSourceTextDifferenceOmittedCount,
                    to: &lines
                )
                appendEvidence(
                    change.revisedTextDifferences,
                    label: "Inserted",
                    serviceOmittedCount:
                        change
                            .resolvedRevisedTextDifferenceOmittedCount,
                    to: &lines
                )
                lines.append("")
            }
            let omitted = orderedChanges.count
                - min(
                    orderedChanges.count,
                    Self.maximumReportedChanges
                )
            if omitted > 0 {
                lines.append(
                    "\(omitted) additional changed pages were omitted by the local report safety limit."
                )
                lines.append("")
            }
        }

        lines.append(contentsOf: [
            "## Scope",
            "",
            "This report was generated on device from PaperPath's local comparison evidence.",
            "It may include bounded text snippets, but it does not include either PDF file.",
            "Vector boundaries come from a bounded scan of common PDF path operators and are included only when they intersect rendered visual changes; unsupported or over-budget content falls back to pixel evidence.",
            "Manual page matches are user-confirmed alignment anchors for this comparison and do not certify document identity.",
            "Repeated identical templates are paired by stable document order between stronger anchors; this deterministic alignment does not prove semantic identity between indistinguishable page instances.",
            "The embedded Ed25519 signature detects report changes and identifies a signing key.",
            "It is not a digital certificate, verified legal identity, or legal attestation.",
            ""
        ])
        return lines.joined(separator: "\n")
    }

    private func appendEvidence(
        _ evidence: [PDFTextDifferenceEvidence]?,
        label: String,
        serviceOmittedCount: Int,
        to lines: inout [String]
    ) {
        let evidence = evidence ?? []
        let boundedServiceOmittedCount = max(
            0,
            serviceOmittedCount
        )
        guard !evidence.isEmpty || boundedServiceOmittedCount > 0
        else { return }
        for item in evidence.prefix(Self.maximumEvidencePerSide) {
            let region = item.region
            lines.append(
                "- \(label) \(item.resolvedGranularity.title.lowercased()) text: \"\(markdownInline(item.text, limit: Self.maximumEvidenceCharacters))\" at x \(decimal(region.x)), y \(decimal(region.y)), w \(decimal(region.width)), h \(decimal(region.height))"
            )
        }
        let reportOmittedCount = max(
            0,
            evidence.count - Self.maximumEvidencePerSide
        )
        let (combinedOmittedCount, overflow) =
            boundedServiceOmittedCount.addingReportingOverflow(
                reportOmittedCount
            )
        let omittedCount = overflow ? Int.max : combinedOmittedCount
        if omittedCount > 0 {
            lines.append(
                "- \(label) text evidence omitted: \(omittedCount)"
            )
        }
    }

    private func pagePairLabel(_ change: PDFPageChange) -> String {
        let source = change.resolvedSourcePageIndex.map {
            "Base \($0 + 1)"
        } ?? "Base missing"
        let revised = change.resolvedRevisedPageIndex.map {
            "Revised \($0 + 1)"
        } ?? "Revised missing"
        return "\(source) -> \(revised)"
    }

    private func identifier(_ value: UUID?) -> String {
        value?.uuidString ?? "Unavailable"
    }

    private func fingerprint(_ value: String?) -> String {
        normalizedFingerprint(value) ?? "Unavailable"
    }

    private func percent(_ value: Double) -> String {
        String(
            format: "%.3f%%",
            locale: Locale(identifier: "en_US_POSIX"),
            min(1, max(0, value)) * 100
        )
    }

    private func decimal(_ value: Double) -> String {
        String(
            format: "%.4f",
            locale: Locale(identifier: "en_US_POSIX"),
            min(1, max(0, value))
        )
    }

    private func markdownInline(
        _ value: String,
        limit: Int = 240
    ) -> String {
        let flattened = sanitizedPlainText(value)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let bounded = String(flattened.prefix(limit))
            + (flattened.count > limit ? "..." : "")
        return bounded
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "!", with: "\\!")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private func metadataText(_ value: String) -> String {
        let flattened = sanitizedPlainText(value)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(
            (flattened.isEmpty ? "PDF" : flattened).prefix(240)
        )
    }

    private func sanitizedPlainText(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                codePoint == 0x061C
                || codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || isBidirectionalControl {
                return " "
            }
            return String(scalar)
        }
        .joined()
    }

    private func normalizedFingerprint(
        _ value: String?
    ) -> String? {
        guard let value,
              value.count == 64,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(
                      charactersIn: "0123456789abcdefABCDEF"
                  ).contains($0)
              })
        else { return nil }
        return value.lowercased()
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func keyID(_ publicKeyData: Data) -> String {
        SHA256.hash(data: publicKeyData)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

#if DEBUG
struct DeviceGoldenPathCaseResult: Codable, Sendable {
    let id: String
    let passed: Bool
    let durationMilliseconds: Int
    let details: [String: String]
    let failure: String?
}

struct DeviceGoldenPathReport: Codable, Sendable {
    let schemaVersion: Int
    let startedAt: Date
    let finishedAt: Date
    let operatingSystem: String
    let deviceModel: String
    let results: [DeviceGoldenPathCaseResult]

    var passed: Bool {
        results.count == 3 && results.allSatisfy(\.passed)
    }
}

enum DeviceGoldenPathDiagnostics {
    private actor PageVisits {
        var indices: [Int] = []
        func append(_ index: Int) { indices.append(index) }
    }

    static func run(reportURL: URL) async {
        let startedAt = Date()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-DeviceGoldenPath-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try LocalFileSecurity.prepareProtectedDirectory(at: root)
            try writeStatus(
                ["status": "running", "startedAt": ISO8601DateFormatter()
                    .string(from: startedAt)],
                to: reportURL
            )
            var results: [DeviceGoldenPathCaseResult] = []
            results.append(
                await runCase(id: "fill-sign-verify") {
                    try fillSignVerify(in: root)
                }
            )
            results.append(
                await runCase(id: "redact-verify") {
                    try redactVerify(in: root)
                }
            )
            results.append(
                await runCase(id: "scan-ocr-verify") {
                    try await scanOCRVerify(in: root)
                }
            )
            results.append(
                await runCase(id: "ocr-page-recovery") {
                    try await ocrPageRecovery(in: root)
                }
            )
            if ProcessInfo.processInfo.arguments.contains("UITEST_COMPETITIVE") {
                results.append(
                    await runCase(id: "batch-completion-recovery") {
                        try await batchCompletionRecovery(in: root)
                    }
                )
            }
            let deviceModel = await MainActor.run {
                UIDevice.current.model
            }
            let report = DeviceGoldenPathReport(
                schemaVersion: 1,
                startedAt: startedAt,
                finishedAt: Date(),
                operatingSystem:
                    ProcessInfo.processInfo.operatingSystemVersionString,
                deviceModel: deviceModel,
                results: results
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(
                to: reportURL,
                options: .atomic
            )
            try LocalFileSecurity.requireCompleteProtection(to: reportURL)
            if (ProcessInfo.processInfo.arguments.contains("UITEST_COMPETITIVE_FIXTURE")
                || ProcessInfo.processInfo.arguments.contains("UITEST_RECOVERY_FIXTURE")),
               results.allSatisfy(\.passed) {
                let fixture = reportURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        ProcessInfo.processInfo.arguments.contains("UITEST_RECOVERY_FIXTURE")
                            ? "RecoveryFixture" : "CompetitiveFixture",
                        isDirectory: true
                    )
                if !FileManager.default.fileExists(atPath: fixture.path) {
                    try FileManager.default.copyItem(
                        at: root.appendingPathComponent("BatchRecovery"),
                        to: fixture
                    )
                }
            }
        } catch {
            try? writeStatus(
                [
                    "status": "failed",
                    "failure": AppLocalization
                        .userFacingErrorDescription(error)
                ],
                to: reportURL
            )
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func runCase(
        id: String,
        operation: () async throws -> [String: String]
    ) async -> DeviceGoldenPathCaseResult {
        let started = Date()
        do {
            let details = try await operation()
            return DeviceGoldenPathCaseResult(
                id: id,
                passed: true,
                durationMilliseconds: Int(
                    Date().timeIntervalSince(started) * 1_000
                ),
                details: details,
                failure: nil
            )
        } catch {
            return DeviceGoldenPathCaseResult(
                id: id,
                passed: false,
                durationMilliseconds: Int(
                    Date().timeIntervalSince(started) * 1_000
                ),
                details: [:],
                failure: AppLocalization
                    .userFacingErrorDescription(error)
            )
        }
    }

    private static func fillSignVerify(
        in root: URL
    ) throws -> [String: String] {
        let source = root.appendingPathComponent("fill-sign-source.pdf")
        let output = root.appendingPathComponent("fill-sign-verified.pdf")
        try DemoPDFBuilder.create(at: source)
        let incomplete = try PDFDeliveryAuditService().preflight(sourceURL: source)
        guard incomplete.status == .review,
              incomplete.items.contains(where: {
                  $0.id == "form-completion" && $0.status == .review && $0.reviewPageIndex == 0
              })
        else {
            throw PaperPathError.outputVerificationFailed(
                "the incomplete form was not flagged before delivery"
            )
        }
        let unfinishedOutput = root.appendingPathComponent("unfinished-form.pdf")
        try PDFOutputService().safeShare(sourceURL: source, destination: unfinishedOutput)
        let unfinishedReceipt = try PDFDeliveryAuditService().audit(
            sourceURL: source, outputURL: unfinishedOutput, operation: .safeShare
        )
        guard unfinishedReceipt.checks.contains(where: {
            $0.id == "source-form-completion" && $0.status == .warning
        }) else {
            throw PaperPathError.outputVerificationFailed(
                "the unfinished-fields warning was not retained in the output receipt"
            )
        }
        guard let document = PDFDocument(url: source),
              let nameField = document.page(at: 0)?.annotations.first(
                where: { $0.fieldName == "Recipient name" }
              )
        else {
            throw PaperPathError.outputVerificationFailed(
                "the recipient field could not be opened"
            )
        }
        nameField.widgetStringValue = "PaperPath Device Test"
        guard document.write(to: source) else {
            throw PaperPathError.storageFailure(
                "The completed form could not be saved."
            )
        }
        try PDFMutationService().addInk(
            PDFInkPayload(
                pageIndex: 1,
                strokes: [
                    PDFInkStroke(
                        points: [
                            PDFInkPoint(x: 0.08, y: 0.72),
                            PDFInkPoint(x: 0.31, y: 0.24),
                            PDFInkPoint(x: 0.52, y: 0.68),
                            PDFInkPoint(x: 0.86, y: 0.18)
                        ],
                        color: PDFInkColor(
                            red: 0.05,
                            green: 0.12,
                            blue: 0.2,
                            alpha: 1
                        ),
                        normalizedLineWidth: 0.035
                    )
                ],
                placement: .signature,
                normalizedBounds: PDFNormalizedRect(
                    x: 0.49,
                    y: 0.81,
                    width: 0.36,
                    height: 0.08
                )
            ),
            in: source
        )
        let form = try PDFFormInspectionService().inspect(url: source)
        guard form.fields.contains(where: {
            $0.name == "Recipient name"
                && $0.value == "PaperPath Device Test"
        }) else {
            throw PaperPathError.outputVerificationFailed(
                "the filled value did not persist"
            )
        }
        let annotations = try PDFMutationService().annotations(in: source)
        guard annotations.contains(where: {
            $0.contents == "Signature"
        }) else {
            throw PaperPathError.outputVerificationFailed(
                "the signature annotation did not persist"
            )
        }
        let completed = try PDFDeliveryAuditService().preflight(sourceURL: source)
        guard completed.items.contains(where: {
            $0.id == "form-completion" && $0.status == .passed
        }) else {
            throw PaperPathError.outputVerificationFailed(
                "the completed form did not clear the unfinished-fields warning"
            )
        }
        try PDFOutputService().safeShare(
            sourceURL: source,
            destination: output
        )
        let receipt = try PDFDeliveryAuditService().audit(
            sourceURL: source,
            outputURL: output,
            operation: .safeShare
        )
        guard receipt.isVerified,
              receipt.outputPageCount == 2,
              receipt.renderedPageCount == 2,
              receipt.sha256.count == 64
        else {
            throw PaperPathError.outputVerificationFailed(
                "the filled and signed output did not pass verification"
            )
        }
        return [
            "formValue": "persisted",
            "signature": "persisted",
            "formPreflight": "incomplete flagged; completed cleared",
            "unfinishedFormReceipt": "warning retained",
            "pages": "\(receipt.outputPageCount)",
            "sha256": receipt.sha256
        ]
    }

    private static func redactVerify(
        in root: URL
    ) throws -> [String: String] {
        let source = root.appendingPathComponent("redact-source.pdf")
        let output = root.appendingPathComponent("redact-verified.pdf")
        try makeTextPDF(
            at: source,
            text: "CONFIDENTIAL ACCOUNT 4827"
        )
        try PDFOutputService().secureRedact(
            sourceURL: source,
            destination: output,
            marks: [
                PDFRedactionMark(
                    pageIndex: 0,
                    normalizedX: 0,
                    normalizedY: 0,
                    normalizedWidth: 1,
                    normalizedHeight: 1
                )
            ]
        )
        let reopened = try requirePDF(at: output)
        guard reopened.page(at: 0)?.string?
            .contains("4827") != true
        else {
            throw PaperPathError.outputVerificationFailed(
                "redacted text remained recoverable"
            )
        }
        let receipt = try PDFDeliveryAuditService().audit(
            sourceURL: source,
            outputURL: output,
            operation: .redacted
        )
        guard receipt.isVerified,
              receipt.outputPageCount == 1,
              receipt.renderedPageCount == 1,
              receipt.sha256.count == 64
        else {
            throw PaperPathError.outputVerificationFailed(
                "the redacted output did not pass verification"
            )
        }
        return [
            "recoverableSensitiveText": "none",
            "pages": "\(receipt.outputPageCount)",
            "sha256": receipt.sha256
        ]
    }

    private static func scanOCRVerify(
        in root: URL
    ) async throws -> [String: String] {
        let scan = root.appendingPathComponent("scan-source.pdf")
        let searchable = root.appendingPathComponent("scan-searchable.pdf")
        let verified = root.appendingPathComponent("scan-verified.pdf")
        let image = makeScanImage()
        try ScanPDFRenderer().render(images: [image], to: scan)
        let scanDocument = try requirePDF(at: scan)
        guard scanDocument.pageCount == 1,
              scanDocument.page(at: 0)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty != false
        else {
            throw PaperPathError.outputVerificationFailed(
                "the scan unexpectedly contained a source text layer"
            )
        }
        let recognition = try await VisionOCRService().recognize(
            url: scan,
            configuration: OCRRecognitionConfiguration(
                languageMode: .selected,
                languageIdentifiers: [
                    OCRRecognitionLanguage.english.rawValue
                ],
                customWords: ["PaperPath"]
            )
        )
        let recognized = recognition.text.uppercased()
        guard recognized.contains("PAPERPATH"),
              recognized.contains("4827")
        else {
            throw PaperPathError.outputVerificationFailed(
                "Vision did not recognize the golden-path phrase"
            )
        }
        try SearchablePDFService().createSearchableCopy(
            sourceURL: scan,
            ocrResult: recognition,
            destination: searchable
        )
        let searchableDocument = try requirePDF(at: searchable)
        guard searchableDocument.string?.uppercased()
            .contains("PAPERPATH") == true
        else {
            throw PaperPathError.outputVerificationFailed(
                "the searchable text layer did not persist"
            )
        }
        try PDFOutputService().safeShare(
            sourceURL: searchable,
            destination: verified
        )
        let receipt = try PDFDeliveryAuditService().audit(
            sourceURL: searchable,
            outputURL: verified,
            operation: .safeShare
        )
        guard receipt.isVerified,
              receipt.outputPageCount == 1,
              receipt.renderedPageCount == 1,
              receipt.sha256.count == 64
        else {
            throw PaperPathError.outputVerificationFailed(
                "the OCR output did not pass verification"
            )
        }
        return [
            "recognizedCharacters": "\(recognition.text.count)",
            "searchableText": "persisted",
            "pages": "\(receipt.outputPageCount)",
            "sha256": receipt.sha256
        ]
    }

    private static func ocrPageRecovery(in root: URL) async throws -> [String: String] {
        let scan = root.appendingPathComponent("recovery-scan.pdf")
        let image = makeScanImage()
        try ScanPDFRenderer().render(images: [image, image, image], to: scan)
        let originalHash = SHA256.hash(data: try Data(contentsOf: scan))
        let storeRoot = root.appendingPathComponent("OCRRecovery", isDirectory: true)
        let store = DocumentStore(rootURL: storeRoot)
        let record = try await store.importPDF(from: scan, preserveSourceLocation: false)
        let source = await store.url(for: record)
        let service = VisionOCRService()
        let configuration = try service.validated(.automatic)
        let identity = OCRCheckpointIdentity(
            recordID: record.id, revisionID: record.contentRevisionID,
            pageCount: 3, configuration: configuration
        )
        let initial = try await store.prepareOCRCheckpoint(identity)
        for pageIndex in [-1, 3] {
            do {
                try await store.saveOCRCheckpointPage(
                    OCRPageResult(pageIndex: pageIndex, text: "invalid", confidence: 1),
                    identity: identity
                )
                throw PaperPathError.outputVerificationFailed("an invalid checkpoint page was saved")
            } catch PaperPathError.invalidPage {}
        }
        do {
            _ = try await service.recognize(
                url: source, configuration: configuration, checkpoint: initial,
                onPageCompleted: { page in
                    try await store.saveOCRCheckpointPage(page, identity: identity)
                    throw CancellationError()
                }
            )
            throw PaperPathError.outputVerificationFailed("recognition did not stop")
        } catch is CancellationError {}
        let reopenedStore = DocumentStore(rootURL: storeRoot)
        guard let saved = try await reopenedStore.loadOCRCheckpoint(identity),
              saved.pages.map(\.pageIndex) == [0],
              try await reopenedStore.loadOCRResults().isEmpty
        else { throw PaperPathError.outputVerificationFailed("partial OCR was not isolated and persisted") }
        guard let summary = try await reopenedStore.loadOCRRecoverySummary(for: record),
              summary.completedPageIndices == [0], summary.damagedPageCount == 0 else {
            throw PaperPathError.outputVerificationFailed("OCR summary did not match the saved pages")
        }
        let visits = PageVisits()
        let resumed = try await service.recognize(
            url: source, configuration: configuration, checkpoint: saved,
            onPageCompleted: { page in
                await visits.append(page.pageIndex)
                try await reopenedStore.saveOCRCheckpointPage(page, identity: identity)
            }
        )
        guard await visits.indices == [1, 2], resumed.pages.count == 3 else {
            throw PaperPathError.outputVerificationFailed("completed OCR pages were recomputed")
        }
        let damaged = storeRoot.appendingPathComponent(
            "OCR/\(record.id.uuidString).resume/page-1.json"
        )
        try Data("{".utf8).write(to: damaged, options: .atomic)
        guard let salvaged = try await reopenedStore.loadOCRCheckpoint(identity),
              salvaged.pages.map(\.pageIndex) == [0, 2] else {
            throw PaperPathError.outputVerificationFailed("a damaged page discarded completed sibling pages")
        }
        guard let summary = try await reopenedStore.loadOCRRecoverySummary(for: record),
              summary.completedPageIndices == [0, 2], summary.damagedPageCount == 1 else {
            throw PaperPathError.outputVerificationFailed("OCR summary counted damaged text as complete")
        }
        let repairVisits = PageVisits()
        _ = try await service.recognize(
            url: source, configuration: configuration, checkpoint: salvaged,
            onPageCompleted: { page in
                await repairVisits.append(page.pageIndex)
                try await reopenedStore.saveOCRCheckpointPage(page, identity: identity)
            }
        )
        guard await repairVisits.indices == [1] else {
            throw PaperPathError.outputVerificationFailed("OCR checkpoint repair did not stay page-local")
        }
        var oldEngine = identity
        oldEngine.engineVersion = 0
        do {
            _ = try await reopenedStore.loadOCRCheckpoint(oldEngine)
            throw PaperPathError.outputVerificationFailed("old OCR engine checkpoint was accepted")
        } catch is CancellationError {}
        let stale = OCRCheckpointIdentity(
            recordID: record.id, revisionID: UUID(), pageCount: 3, configuration: configuration
        )
        do {
            try await reopenedStore.saveOCRCheckpointPage(resumed.pages[0], identity: stale)
            throw PaperPathError.outputVerificationFailed("stale OCR revision was written")
        } catch is CancellationError {}
        let changed = OCRCheckpointIdentity(
            recordID: record.id, revisionID: record.contentRevisionID, pageCount: 3,
            configuration: OCRRecognitionConfiguration(
                languageMode: .selected, languageIdentifiers: ["en-US"], customWords: ["Invoice"]
            )
        )
        guard try await reopenedStore.loadOCRCheckpoint(changed) == nil else {
            throw PaperPathError.outputVerificationFailed("changed OCR settings reused old text")
        }
        let restarted = try await reopenedStore.prepareOCRCheckpoint(changed)
        guard restarted.pages.isEmpty else {
            throw PaperPathError.outputVerificationFailed("new OCR configuration was not isolated")
        }
        try await reopenedStore.saveOCRCheckpointPage(resumed.pages[0], identity: changed)
        let recoveredSettings = try await reopenedStore.loadOCRRecoverySummary(for: record)
        guard recoveredSettings?.identity.configuration == changed.configuration,
              recoveredSettings?.completedPageCount == 1,
              try await reopenedStore.loadOCRCheckpoint(identity) == nil,
              try await reopenedStore.loadOCRCheckpoint(changed)?.pages.count == 1 else {
            throw PaperPathError.outputVerificationFailed("saved OCR settings were not discoverable or were overwritten by reading")
        }
        do {
            try await reopenedStore.saveOCRCheckpointPage(resumed.pages[0], identity: identity)
            throw PaperPathError.outputVerificationFailed("an old OCR worker replaced a new configuration")
        } catch is CancellationError {}
        try await reopenedStore.removeOCRCheckpoint(changed)
        guard try await reopenedStore.loadOCRCheckpoint(changed) == nil,
              SHA256.hash(data: try Data(contentsOf: scan)) == originalHash else {
            throw PaperPathError.outputVerificationFailed("OCR cleanup altered the source")
        }
        _ = try await reopenedStore.prepareOCRCheckpoint(identity)
        for page in resumed.pages {
            try await reopenedStore.saveOCRCheckpointPage(page, identity: identity)
        }
        let model = await PaperPathModel(store: reopenedStore)
        try await model.loadWorkflowDiagnosticSnapshot()
        guard await model.recognizeText(recordID: record.id, configuration: configuration),
              try await reopenedStore.loadOCRResults()[record.id]?.pages.count == 3,
              try await reopenedStore.loadOCRCheckpoint(identity) == nil else {
            throw PaperPathError.outputVerificationFailed("completed OCR analysis was not committed and cleaned")
        }
        return [
            "resume": "one saved page; only pages 2 and 3 recognized",
            "corruption": "only damaged page 2 recomputed",
            "invalidation": "revision, configuration and engine rejected",
            "partialAnalysis": "not published",
            "finalAnalysis": "three pages committed; checkpoint removed",
            "invalidPages": "negative and out-of-range rejected",
            "summary": "valid pages counted; damaged page excluded",
            "savedSettings": "language and vocabulary discovered without changing checkpoint",
            "original": "SHA-256 unchanged"
        ]
    }

    @MainActor
    private static func batchCompletionRecovery(in root: URL) async throws -> [String: String] {
        let storeRoot = root.appendingPathComponent("BatchRecovery", isDirectory: true)
        let store = DocumentStore(rootURL: storeRoot)
        let cleanURL = root.appendingPathComponent("batch-ready.pdf")
        try makeTextPDF(at: cleanURL, text: "PaperPath project delivery 4827")
        let formURL = root.appendingPathComponent("batch-form.pdf")
        try DemoPDFBuilder.create(at: formURL)
        let ready = try await store.importPDF(from: cleanURL, preserveSourceLocation: false)
        let form = try await store.importPDF(from: formURL, preserveSourceLocation: false)
        let unchecked = try await store.importPDF(from: cleanURL, preserveSourceLocation: false)
        let unknown = PDFDeliveryPreflightAssessment(
            status: .review, pageCount: 1, byteCount: 100, fixCount: 0, reviewCount: 1,
            items: [PDFDeliveryPreflightItem(
                id: "form-inspection-limit", title: "Form completion not checked",
                detail: "This PDF exceeds the quick form-check limit. Review its fields before sending.",
                status: .review
            )]
        )
        try await store.saveDeliveryPreflight(PDFDeliveryPreflightCacheEntry(
            recordID: unchecked.id, revisionID: unchecked.contentRevisionID,
            checkedAt: Date(), assessment: unknown
        ))
        let model = PaperPathModel(store: store)
        try await model.loadWorkflowDiagnosticSnapshot()
        let runID = UUID()
        guard model.beginBatchDeliveryRun(id: runID),
              !model.beginBatchDeliveryRun(id: UUID()) else {
            throw PaperPathError.outputVerificationFailed("concurrent batch ownership was not rejected")
        }
        let started = Date()
        let records = [ready, form, unchecked]
        let results = await model.createSafeShareBatch(
            recordIDs: records.map(\.id), runID: runID, onUpdate: { _ in }
        )
        model.endBatchDeliveryRun(id: runID)
        guard results.first(where: { $0.sourceRecordID == ready.id })?.stage == .verified,
              results.first(where: { $0.sourceRecordID == form.id })?.stage == .needsReview,
              results.first(where: { $0.sourceRecordID == unchecked.id })?.stage == .needsReview,
              results.filter({ $0.outputRecordID != nil }).count == 1 else {
            throw PaperPathError.outputVerificationFailed("a mixed batch bypassed a review gate")
        }
        let revisions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.contentRevisionID) })
        guard await model.saveBatchDeliveryRun(
            id: runID, sourceRecordIDs: records.map(\.id), sourceRevisionIDs: revisions,
            items: results, startedAt: started
        ) else { throw PaperPathError.outputVerificationFailed("batch results did not persist") }
        let reopened = PaperPathModel(store: DocumentStore(rootURL: storeRoot))
        try await reopened.loadWorkflowDiagnosticSnapshot()
        guard reopened.currentBatchDeliveryRun()?.items.filter({ $0.stage.isShareable }).count == 1 else {
            throw PaperPathError.outputVerificationFailed("durable batch output was not restored")
        }
        let outputsBefore = reopened.documents.count
        let reuse = await reopened.createSafeShareBatch(recordIDs: [ready.id], onUpdate: { _ in })
        guard reuse.first?.stage == .reused, reopened.documents.count == outputsBefore else {
            throw PaperPathError.outputVerificationFailed("retry duplicated an already completed output")
        }
        let completedID = UUID()
        let completedAt = Date()
        guard await reopened.saveBatchDeliveryRun(
            id: completedID, sourceRecordIDs: [ready.id],
            sourceRevisionIDs: [ready.id: ready.contentRevisionID], items: reuse,
            startedAt: completedAt
        ) else { throw PaperPathError.outputVerificationFailed("completed batch was not saved") }
        let persistedBatch = try await store.loadBatchDeliveryRun()
        guard persistedBatch?.startedAt.timeIntervalSince1970 == completedAt.timeIntervalSince1970 else {
            throw PaperPathError.outputVerificationFailed("batch timestamp precision was lost")
        }
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        try legacyEncoder.encode(persistedBatch).write(
            to: storeRoot.appendingPathComponent("last-batch-delivery.json"), options: .atomic
        )
        guard try await store.loadBatchDeliveryRun()?.id == completedID,
              let persistedBatch else {
            throw PaperPathError.outputVerificationFailed("legacy batch timestamps could not be read")
        }
        try await store.saveBatchDeliveryRun(persistedBatch)
        let completed = PaperPathModel(store: DocumentStore(rootURL: storeRoot))
        try await completed.loadWorkflowDiagnosticSnapshot()
        guard completed.currentBatchDeliveryRun()?.id == completedID,
              completed.recoverableBatchDeliveryRun() == nil else {
            throw PaperPathError.outputVerificationFailed("completed history was confused with unfinished recovery")
        }
        let staleSave = await completed.saveBatchDeliveryRun(
            id: runID, sourceRecordIDs: records.map(\.id), sourceRevisionIDs: revisions,
            items: results, startedAt: started, snapshotAt: started
        )
        guard !staleSave, completed.currentBatchDeliveryRun()?.id == completedID else {
            throw PaperPathError.outputVerificationFailed("an older snapshot overwrote the completed batch")
        }
        guard await completed.saveBatchDeliveryRun(
            id: completedID, sourceRecordIDs: [ready.id],
            sourceRevisionIDs: [ready.id: ready.contentRevisionID], items: reuse,
            startedAt: completedAt.addingTimeInterval(-0.000_001)
        ) else {
            throw PaperPathError.outputVerificationFailed("same-batch timestamp round-off rejected a fresh snapshot")
        }
        var invalid = reuse
        invalid[0].detail = String(repeating: "x", count: 2_001)
        let failedSave = await completed.saveBatchDeliveryRun(
            id: completedID, sourceRecordIDs: [ready.id],
            sourceRevisionIDs: [ready.id: ready.contentRevisionID], items: invalid,
            startedAt: completedAt
        )
        let durable = try await store.loadBatchDeliveryRun()
        guard !failedSave else {
            throw PaperPathError.outputVerificationFailed("an invalid batch snapshot was accepted")
        }
        guard completed.batchDeliveryPersistenceError != nil else {
            throw PaperPathError.outputVerificationFailed("batch persistence failure was not visible")
        }
        guard durable?.items == reuse else {
            throw PaperPathError.outputVerificationFailed("failed batch save discarded the previous durable result")
        }
        guard await completed.saveBatchDeliveryRun(
            id: completedID, sourceRecordIDs: [ready.id],
            sourceRevisionIDs: [ready.id: ready.contentRevisionID], items: reuse,
            startedAt: completedAt
        ), completed.batchDeliveryPersistenceError == nil else {
            throw PaperPathError.outputVerificationFailed("batch save retry did not clear its failure")
        }
        let revisionRunID = UUID()
        let revisionRunStarted = Date()
        guard await completed.saveBatchDeliveryRun(
            id: revisionRunID, sourceRecordIDs: records.map(\.id), sourceRevisionIDs: revisions,
            items: results, startedAt: revisionRunStarted
        ) else { throw PaperPathError.outputVerificationFailed("revision recovery fixture was not saved") }
        let updatedURL = await store.url(for: unchecked)
        try makeTextPDF(at: updatedURL, text: "Updated delivery revision 4828")
        let updated = try await store.refresh(unchecked, invalidateAnalysis: true)
        let revisionModel = PaperPathModel(store: DocumentStore(rootURL: storeRoot))
        try await revisionModel.loadWorkflowDiagnosticSnapshot()
        guard let retainedRun = revisionModel.currentBatchDeliveryRun(),
              retainedRun.sourceRecordIDs.count == 3,
              let changedItem = retainedRun.items.first(where: { $0.sourceRecordID == unchecked.id }),
              changedItem.stage == .needsReview,
              changedItem.outputRecordID == nil,
              changedItem.reviewPageIndex == nil else {
            throw PaperPathError.outputVerificationFailed("revised source disappeared or retained stale evidence")
        }
        guard await revisionModel.saveBatchDeliveryRun(
            id: revisionRunID, sourceRecordIDs: records.map(\.id), sourceRevisionIDs: revisions,
            items: results, startedAt: revisionRunStarted
        ), try await store.loadBatchDeliveryRun()?.sourceRecordIDs.count == 3 else {
            throw PaperPathError.outputVerificationFailed("persisting revised batch removed its changed source")
        }
        let outdatedRequest = await revisionModel.createSafeShareBatch(
            recordIDs: [updated.id], expectedRevisionIDs: revisions, onUpdate: { _ in }
        )
        guard outdatedRequest.first?.stage == .needsReview,
              outdatedRequest.first?.outputRecordID == nil else {
            throw PaperPathError.outputVerificationFailed("batch silently adopted an unconfirmed revision")
        }
        let beforeRecheckCount = revisionModel.documents.count
        let rechecked = await revisionModel.createSafeShareBatch(
            recordIDs: [updated.id], expectedRevisionIDs: [updated.id: updated.contentRevisionID],
            onUpdate: { _ in }
        )
        guard rechecked.first?.stage == .verified,
              revisionModel.documents.count == beforeRecheckCount + 1,
              let originalOutputID = results.first(where: { $0.sourceRecordID == ready.id })?.outputRecordID,
              revisionModel.record(id: originalOutputID) != nil else {
            throw PaperPathError.outputVerificationFailed("rechecking current revision lost an existing output")
        }
        if ProcessInfo.processInfo.arguments.contains("UITEST_COMPETITIVE_FIXTURE")
            || ProcessInfo.processInfo.arguments.contains("UITEST_RECOVERY_FIXTURE") {
            _ = await completed.saveBatchDeliveryRun(
                id: UUID(), sourceRecordIDs: records.map(\.id), sourceRevisionIDs: revisions,
                items: results, startedAt: Date()
            )
            let scan = try await store.importPDF(
                from: root.appendingPathComponent("recovery-scan.pdf"),
                preferredName: "OCR recovery sample", preserveSourceLocation: false
            )
            let identity = OCRCheckpointIdentity(
                recordID: scan.id, revisionID: scan.contentRevisionID,
                pageCount: 3, configuration: OCRRecognitionConfiguration(
                    languageMode: .selected, languageIdentifiers: ["en-US"],
                    customWords: ["PaperPath", "Invoice"]
                )
            )
            let checkpoint = try await store.prepareOCRCheckpoint(identity)
            do {
                _ = try await VisionOCRService().recognize(
                    url: store.url(for: scan), configuration: identity.configuration, checkpoint: checkpoint,
                    onPageCompleted: { page in
                        try await store.saveOCRCheckpointPage(page, identity: identity)
                        throw CancellationError()
                    }
                )
            } catch is CancellationError {}
            if ProcessInfo.processInfo.arguments.contains("UITEST_USABILITY") {
                let galleryModel = PaperPathModel(store: store)
                try await galleryModel.loadWorkflowDiagnosticSnapshot()
                let portfolio = PDFOfficeExportPortfolio(profile: ready.profile)
                for index in 1...13 {
                    let artifact = try await galleryModel.makeTextExport(
                        recordID: ready.id, format: .plainText,
                        expectedContentRevisionID: ready.contentRevisionID
                    )
                    let receipt = PDFOfficeExportReceipt(
                        format: .plainText,
                        fileName: String(format: "Delivery note %02d.txt", index),
                        fileSizeBytes: Int64(
                            try artifact.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        ),
                        plan: portfolio.plan(for: .plainText),
                        budgetPlan: portfolio.visualBudgetPlan,
                        portfolio: portfolio,
                        runtimeEvidence: artifact.runtimeEvidence
                    )
                    guard await galleryModel.retainOfficeExport(
                        recordID: ready.id, receipt: receipt, sourceURL: artifact.url,
                        expectedContentRevisionID: ready.contentRevisionID
                    ) != nil else {
                        throw PaperPathError.outputVerificationFailed("usability history artifact was not retained")
                    }
                }
            }
        }
        return [
            "mixedBatch": "1 verified; 2 review; no unchecked output",
            "restart": "completed output and fully completed batch retained",
            "retry": "existing verified copy reused; no duplicate",
            "persistenceFailure": "visible; previous disk result preserved; retry cleared",
            "staleSnapshot": "rejected",
            "timestampMigration": "precise round trip; legacy ISO-8601 accepted",
            "sameBatchRoundoff": "fresh snapshot accepted with canonical start",
            "changedSource": "retained; old output and page target cleared",
            "recheck": "unconfirmed revision blocked; confirmed revision checked; earlier output retained",
            "concurrency": "second batch owner rejected"
        ]
    }

    private static func makeTextPDF(
        at url: URL,
        text: String
    ) throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            UIColor.white.setFill()
            context.fill(bounds)
            text.draw(
                in: CGRect(x: 56, y: 96, width: 500, height: 120),
                withAttributes: [
                    .font: UIFont.systemFont(
                        ofSize: 28,
                        weight: .bold
                    ),
                    .foregroundColor: UIColor.black
                ]
            )
        }
    }

    private static func makeScanImage() -> UIImage {
        let size = CGSize(width: 1_600, height: 2_200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: size,
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            let border = UIBezierPath(
                roundedRect: CGRect(
                    x: 90,
                    y: 100,
                    width: 1_420,
                    height: 2_000
                ),
                cornerRadius: 24
            )
            border.lineWidth = 8
            border.stroke()
            "PAPERPATH\nINVOICE\n4827".draw(
                in: CGRect(
                    x: 180,
                    y: 520,
                    width: 1_240,
                    height: 600
                ),
                withAttributes: [
                    .font: UIFont.systemFont(
                        ofSize: 112,
                        weight: .bold
                    ),
                    .foregroundColor: UIColor.black
                ]
            )
        }
    }

    private static func requirePDF(at url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url),
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        return document
    }

    private static func writeStatus(
        _ status: [String: String],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: status,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
        try LocalFileSecurity.requireCompleteProtection(to: url)
    }
}

@MainActor
enum DeviceOfficeCorpusDiagnostics {
    private struct Input: Decodable {
        let id: String
        let input: String
        let format: PDFTextExportFormat
    }

    private struct Result: Encodable {
        let id: String
        let format: PDFTextExportFormat
        let output: String?
        let sourcePageCount: Int
        let sourceTextByPage: [String]
        let runtime: PDFOfficeRuntimeEvidence?
        var persistedNoticesVerified: Bool = false
        let error: String?
    }

    static func run(root: URL) async {
        let manager = FileManager.default
        let runID = UUID().uuidString
        let reportURL = root.appendingPathComponent("report.json")
        var results: [Result] = []
        func save(status: String) throws {
            let encodedResults = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(results)
            )
            try JSONSerialization.data(withJSONObject: [
                "runID": runID, "status": status,
                "system": ProcessInfo.processInfo.operatingSystemVersionString,
                "results": encodedResults
            ], options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        }
        do {
            let cases = try JSONDecoder().decode(
                [Input].self, from: Data(contentsOf: root.appendingPathComponent("cases.json"))
            )
            guard !cases.isEmpty, cases.count <= 30 else {
                throw PaperPathError.insufficientSelection("Expected 1...30 corpus cases.")
            }
            let outputs = root.appendingPathComponent("outputs/\(runID)", isDirectory: true)
            try LocalFileSecurity.prepareProtectedDirectory(at: outputs)
            let store = DocumentStore(rootURL: root.appendingPathComponent("store-\(runID)"))
            let model = PaperPathModel(store: store)
            try save(status: "running")
            for item in cases {
                var pages: [String] = []
                do {
                    guard item.id == URL(fileURLWithPath: item.id).lastPathComponent,
                          item.input == URL(fileURLWithPath: item.input).lastPathComponent,
                          item.input.hasSuffix(".pdf"), item.format.isOfficeFormat
                    else { throw PaperPathError.unreadablePDF }
                    let source = root.appendingPathComponent("inputs").appendingPathComponent(item.input)
                    guard let pdf = PDFDocument(url: source), !pdf.isLocked else {
                        throw PaperPathError.unreadablePDF
                    }
                    pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
                    let record = try await store.importPDF(
                        from: source, preferredName: item.id, preserveSourceLocation: false
                    )
                    try await model.loadWorkflowDiagnosticSnapshot()
                    let artifact = try await model.makeTextExport(
                        recordID: record.id, format: item.format,
                        expectedContentRevisionID: record.contentRevisionID
                    )
                    let filename = "\(item.id).\(item.format.fileExtension)"
                    try manager.copyItem(at: artifact.url, to: outputs.appendingPathComponent(filename))
                    let portfolio = PDFOfficeExportPortfolio(profile: artifact.sourceProfile)
                    var receipt = PDFOfficeExportReceipt(
                        format: item.format, fileName: filename,
                        fileSizeBytes: Int64(try Data(contentsOf: artifact.url).count),
                        plan: portfolio.plan(for: item.format),
                        budgetPlan: portfolio.visualBudgetPlan, portfolio: portfolio,
                        runtimeEvidence: artifact.runtimeEvidence
                    )
                    receipt.sourceRevisionID = record.contentRevisionID
                    guard let retained = await model.retainOfficeExport(
                        recordID: record.id, receipt: receipt, sourceURL: artifact.url,
                        expectedContentRevisionID: record.contentRevisionID
                    ) else {
                        throw PaperPathError.outputVerificationFailed("corpus output did not persist")
                    }
                    let reopened = PaperPathModel(store: DocumentStore(
                        rootURL: root.appendingPathComponent("store-\(runID)")
                    ))
                    try await reopened.loadWorkflowDiagnosticSnapshot()
                    guard let restored = reopened.record(id: record.id)?.officeReceipts.first(where: {
                        $0.id == retained.receipt.id
                    }), restored.contentNotices == receipt.contentNotices,
                       !restored.contentNotices.isEmpty else {
                        throw PaperPathError.outputVerificationFailed("content notices did not survive reload")
                    }
                    results.append(Result(
                        id: item.id, format: item.format,
                        output: "outputs/\(runID)/\(filename)",
                        sourcePageCount: pages.count, sourceTextByPage: pages,
                        runtime: artifact.runtimeEvidence, persistedNoticesVerified: true, error: nil
                    ))
                } catch {
                    results.append(Result(
                        id: item.id, format: item.format, output: nil,
                        sourcePageCount: pages.count, sourceTextByPage: pages,
                        runtime: nil, error: error.localizedDescription
                    ))
                }
                try save(status: "running")
            }
            try save(status: "completed")
        } catch {
            try? JSONSerialization.data(withJSONObject: [
                "status": "failed", "error": error.localizedDescription
            ], options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        }
    }
}
#endif
