import Foundation
import PDFKit

struct HandoffKeyDetailSource: Sendable {
    let document: HandoffDocumentSnapshot
    let privateCopyURL: URL?
    let pageCount: Int
}

/// User-directed, literal field checks. This does not infer business meaning,
/// currency equivalence, date formats, or the completeness of an institution's forms.
struct HandoffKeyDetailService: Sendable {
    private struct TextDocument {
        let pages: [IndexedPageText]
        let complete: Bool
        var emptyState: HandoffKeyDetailState = .unreadable
    }

    func check(packet: HandoffPacket, sources: [UUID: HandoffKeyDetailSource]) throws -> HandoffKeyDetailReport {
        var textByID: [UUID: TextDocument] = [:]
        for (id, source) in sources {
            try Task.checkCancellation()
            textByID[id] = try read(source)
        }
        var results: [HandoffKeyDetailResult] = []
        for detail in packet.detailsToCheck {
            for requirementID in detail.requirementIDs {
                try Task.checkCancellation()
                let item = packet.requirements.first { $0.id == requirementID }
                let id = item?.recordID
                let source = id.flatMap { sources[$0] }
                let text = id.flatMap { textByID[$0] }
                let checked: (HandoffKeyDetailState, [HandoffKeyDetailEvidence])
                if source == nil { checked = (.missingFile, []) }
                else if let text { checked = try evaluate(detail: detail, text: text) }
                else { checked = (.unreadable, []) }
                results.append(HandoffKeyDetailResult(
                    detailID: detail.id, requirementID: requirementID, recordID: id,
                    revisionID: source?.document.revisionID, state: checked.0, evidence: checked.1
                ))
            }
        }
        return HandoffKeyDetailReport(
            version: HandoffKeyDetailReport.currentVersion, checkedAt: Date(), details: packet.detailsToCheck,
            bindings: HandoffKeyDetailBinding.capture(packet: packet, documents: sources.mapValues(\.document)),
            results: results
        )
    }

    private func read(_ source: HandoffKeyDetailSource) throws -> TextDocument {
        if source.pageCount > 100 || source.document.byteCount > 128_000_000 {
            return TextDocument(pages: [], complete: false, emptyState: .incomplete)
        }
        guard !source.document.isLocked, source.pageCount > 0,
              let url = source.privateCopyURL else {
            return TextDocument(pages: [], complete: false)
        }
        // Read the actual selected PDF, not a separately editable OCR draft or
        // search index. Scans must first be made into searchable PDF copies.
        // This never triggers recognition or model downloads as a side effect.
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount == source.pageCount else {
            return TextDocument(pages: [], complete: false)
        }
        var pages: [IndexedPageText] = []
        var remaining = 500_000
        var complete = true
        for pageIndex in 0..<pdf.pageCount {
            try Task.checkCancellation()
            let raw = autoreleasepool { pdf.page(at: pageIndex)?.string ?? "" }
            guard raw.count <= 100_000, raw.count <= remaining else { complete = false; break }
            remaining -= raw.count
            if normalized(raw).isEmpty { complete = false }
            pages.append(IndexedPageText(pageIndex: pageIndex, text: raw))
        }
        return TextDocument(pages: pages, complete: complete && pages.count == source.pageCount, emptyState: .incomplete)
    }

    private func evaluate(detail: HandoffKeyDetail, text: TextDocument) throws -> (HandoffKeyDetailState, [HandoffKeyDetailEvidence]) {
        guard text.pages.contains(where: { !normalized($0.text).isEmpty }) else { return (text.emptyState, []) }
        let label = normalized(detail.label)
        let expected = normalized(detail.expectedText)
        var evidence: [HandoffKeyDetailEvidence] = []
        var values = Set<String>()
        var ambiguous = false
        var limited = false
        for page in text.pages {
            let lines = page.text.components(separatedBy: .newlines)
            for (lineIndex, rawLine) in lines.enumerated() {
                if lineIndex.isMultiple(of: 128) { try Task.checkCancellation() }
                let line = normalized(rawLine)
                guard let range = line.range(of: label, options: [.anchored, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) else { continue }
                let suffix = String(line[range.upperBound...])
                let labelEndsWithSeparator = label.last == ":" || label.last == "="
                guard suffix.isEmpty || suffix.first?.isWhitespace == true || suffix.first == ":" || suffix.first == "=" || labelEndsWithSeparator else { continue }
                var value = String(suffix.drop(while: \.isWhitespace))
                if !labelEndsWithSeparator, value.first == ":" || value.first == "=" { value.removeFirst() }
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty {
                    // A following line is evidence to inspect, never an inferred match.
                    ambiguous = true
                    value = lines.dropFirst(lineIndex + 1).prefix(2).map(normalized).first(where: { !$0.isEmpty }) ?? ""
                }
                if value.contains(":") || value.contains("=") { ambiguous = true }
                if value.count > 160 || rawLine.count > 200 { limited = true }
                let bounded = String(value.prefix(160))
                if values.insert(bounded).inserted, evidence.count < 2 {
                    evidence.append(HandoffKeyDetailEvidence(pageIndex: page.pageIndex, value: bounded, excerpt: String(rawLine.prefix(200))))
                }
            }
        }
        guard !values.isEmpty else { return (text.complete ? .missingField : .incomplete, []) }
        if ambiguous || values.count > 1 { return (.ambiguous, evidence) }
        if limited { return (.incomplete, evidence) }
        if values.first != expected { return (.differs, evidence) }
        return (text.complete ? .matches : .incomplete, evidence)
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
