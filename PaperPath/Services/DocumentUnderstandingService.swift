import Foundation
import PDFKit

enum DocumentSearchNormalization {
    static let maximumQueryCharacters = 512
    static let maximumTermCharacters = 64
    static let maximumTermCount = 16

    static func text(_ value: String) -> String {
        value.folding(
            options: [
                .caseInsensitive,
                .diacriticInsensitive,
                .widthInsensitive
            ],
            locale: nil
        )
        .lowercased()
    }

    static func terms(in query: String) -> [String] {
        normalizedTerms(
            String(query.prefix(maximumQueryCharacters))
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        )
    }

    static func normalizedTerms(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(min(values.count, maximumTermCount))
        for value in values {
            let normalized = text(
                String(value.prefix(maximumTermCharacters))
            )
            guard !normalized.isEmpty,
                  seen.insert(normalized).inserted
            else { continue }
            result.append(normalized)
            if result.count == maximumTermCount {
                break
            }
        }
        return result
    }
}

struct IndexedPageText: Codable, Hashable, Sendable {
    let pageIndex: Int
    let text: String
}

struct DocumentTextMatch: Hashable, Sendable {
    let pageIndex: Int
    let excerpt: String
}

struct DocumentTextSearchEvaluation: Sendable {
    let containsEveryTerm: Bool
    let matches: [DocumentTextMatch]
}

struct DocumentTextIndex: Codable, Hashable, Sendable {
    static let maximumCharacterCount = 500_000
    static let maximumUTF8ByteCount = maximumCharacterCount * 4

    let source: IndexedTextSource
    let pages: [IndexedPageText]
    let indexedAt: Date
    let isTruncated: Bool?
    let contentRevisionID: UUID?

    init(
        source: IndexedTextSource,
        pages: [IndexedPageText],
        indexedAt: Date,
        isTruncated: Bool? = nil,
        contentRevisionID: UUID? = nil
    ) {
        self.source = source
        self.pages = pages
        self.indexedAt = indexedAt
        self.isTruncated = isTruncated
        self.contentRevisionID = contentRevisionID
    }

    func bound(to revisionID: UUID) -> DocumentTextIndex {
        DocumentTextIndex(
            source: source,
            pages: pages,
            indexedAt: indexedAt,
            isTruncated: isTruncated,
            contentRevisionID: revisionID
        )
    }

    var text: String {
        pages.map(\.text).joined(separator: "\n\n")
    }

    var characterCount: Int {
        pages.reduce(0) { count, page in
            let (next, overflow) = count.addingReportingOverflow(
                page.text.count
            )
            return overflow ? .max : next
        }
    }

    var hasTruncatedContent: Bool {
        isTruncated
            ?? (characterCount >= Self.maximumCharacterCount)
    }

    func segment(
        from startPageIndex: Int,
        through endPageIndex: Int
    ) -> DocumentTextIndex {
        guard startPageIndex <= endPageIndex else {
            return DocumentTextIndex(
                source: source,
                pages: [],
                indexedAt: indexedAt,
                isTruncated: hasTruncatedContent
            )
        }
        let startOffset = lowerBoundPageOffset(for: startPageIndex)
        let endOffset = endPageIndex == Int.max
            ? pages.endIndex
            : lowerBoundPageOffset(for: endPageIndex + 1)
        return DocumentTextIndex(
            source: source,
            pages: pages[startOffset..<endOffset].map { page in
                return IndexedPageText(
                    pageIndex: page.pageIndex - startPageIndex,
                    text: page.text
                )
            },
            indexedAt: indexedAt,
            isTruncated: hasTruncatedContent
        )
    }

    private func lowerBoundPageOffset(for pageIndex: Int) -> Int {
        var lower = pages.startIndex
        var upper = pages.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if pages[middle].pageIndex < pageIndex {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    func firstMatchingPage(for query: String) -> Int? {
        firstMatch(for: query)?.pageIndex
    }

    func firstMatch(
        for query: String,
        excerptLimit: Int = 180
    ) -> DocumentTextMatch? {
        matches(
            for: query,
            excerptLimit: excerptLimit,
            limit: 1
        ).first
    }

    func matches(
        for query: String,
        excerptLimit: Int = 180,
        limit: Int = 200
    ) -> [DocumentTextMatch] {
        let terms = DocumentSearchNormalization.terms(in: query)
        let resultLimit = min(max(0, limit), 500)
        guard !terms.isEmpty, resultLimit > 0 else { return [] }
        var results: [DocumentTextMatch] = []
        results.reserveCapacity(min(resultLimit, pages.count))
        for page in pages {
            let searchableText =
                DocumentSearchNormalization.text(page.text)
            guard terms.allSatisfy(searchableText.contains),
                  let result = match(
                      page: page,
                      terms: terms,
                      excerptLimit: excerptLimit
                  )
            else {
                continue
            }
            results.append(result)
            if results.count == resultLimit {
                break
            }
        }
        return results
    }

    func containsEveryTerm(
        _ terms: [String]
    ) throws -> Bool {
        try evaluateSearch(
            normalizedTerms: terms,
            matchLimit: 0
        ).containsEveryTerm
    }

    func cancellableMatches(
        for query: String,
        excerptLimit: Int = 180,
        limit: Int = 200
    ) throws -> [DocumentTextMatch] {
        guard limit > 0 else { return [] }
        let terms = DocumentSearchNormalization.terms(in: query)
        return try evaluateSearch(
            normalizedTerms: terms,
            excerptLimit: excerptLimit,
            matchLimit: limit
        ).matches
    }

    func evaluateSearch(
        normalizedTerms values: [String],
        excerptLimit: Int = 180,
        matchLimit: Int = 200
    ) throws -> DocumentTextSearchEvaluation {
        let terms = DocumentSearchNormalization.normalizedTerms(values)
        let resultLimit = min(max(0, matchLimit), 500)
        guard !terms.isEmpty else {
            return DocumentTextSearchEvaluation(
                containsEveryTerm: true,
                matches: []
            )
        }

        var remaining = Set(terms)
        var results: [DocumentTextMatch] = []
        results.reserveCapacity(min(resultLimit, pages.count))
        for (offset, page) in pages.enumerated() {
            if offset.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            let searchableText =
                DocumentSearchNormalization.text(page.text)
            for term in terms
            where remaining.contains(term)
                && searchableText.contains(term) {
                remaining.remove(term)
            }
            if results.count < resultLimit,
               terms.allSatisfy(searchableText.contains),
               let result = match(
                   page: page,
                   terms: terms,
                   excerptLimit: excerptLimit
               ) {
                results.append(result)
            }
            if remaining.isEmpty,
               resultLimit == 0 || results.count == resultLimit {
                break
            }
        }
        return DocumentTextSearchEvaluation(
            containsEveryTerm: remaining.isEmpty,
            matches: results
        )
    }

    private func match(
        page: IndexedPageText,
        terms: [String],
        excerptLimit: Int
    ) -> DocumentTextMatch? {
        let text = page.text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }

        let firstRange = terms.compactMap {
            text.range(
                of: $0,
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive
                ],
                locale: nil
            )
        }.min {
            $0.lowerBound < $1.lowerBound
        }
        let matchOffset = firstRange.map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
        } ?? 0
        let limit = min(max(48, excerptLimit), 1_000)
        let startOffset = max(0, matchOffset - limit / 3)
        let endOffset = min(text.count, startOffset + limit)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        let prefix = startOffset > 0 ? "…" : ""
        let suffix = endOffset < text.count ? "…" : ""

        return DocumentTextMatch(
            pageIndex: page.pageIndex,
            excerpt: prefix + String(text[start..<end]) + suffix
        )
    }
}

struct PDFTextIndexService: Sendable {
    private static let maximumPageCount = 100_000

    func extractNativeText(from url: URL) throws -> DocumentTextIndex {
        guard let document = PDFDocument(url: url) else {
            throw PaperPathError.unreadablePDF
        }
        guard !document.isLocked else {
            throw PaperPathError.lockedPDF
        }
        guard document.pageCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Index PDFs with up to 100,000 pages."
            )
        }

        var remaining = DocumentTextIndex.maximumCharacterCount
        var pages: [IndexedPageText] = []
        var isTruncated = false
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard remaining > 0 else {
                isTruncated = true
                break
            }
            let normalized: String? = autoreleasepool {
                guard let text = document.page(at: pageIndex)?.string
                else { return nil }
                return text
                    .replacingOccurrences(of: "\u{00a0}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let normalized else { continue }
            guard !normalized.isEmpty else { continue }
            if normalized.count > remaining {
                isTruncated = true
            }
            let pageText = String(normalized.prefix(remaining))
            pages.append(IndexedPageText(pageIndex: pageIndex, text: pageText))
            remaining -= pageText.count
        }

        return DocumentTextIndex(
            source: .native,
            pages: pages,
            indexedAt: Date(),
            isTruncated: isTruncated
        )
    }

    func index(from result: OCRResult) -> DocumentTextIndex {
        var pages: [IndexedPageText] = []
        pages.reserveCapacity(result.pages.count)
        var remaining = DocumentTextIndex.maximumCharacterCount
        var isTruncated = false
        for page in result.pages {
            guard !Task.isCancelled else {
                isTruncated = true
                break
            }
            guard remaining > 0 else {
                isTruncated = true
                break
            }
            if page.text.count > remaining {
                isTruncated = true
            }
            let pageText = String(page.text.prefix(remaining))
            pages.append(
                IndexedPageText(
                    pageIndex: page.pageIndex,
                    text: pageText
                )
            )
            remaining -= pageText.count
        }
        return DocumentTextIndex(
            source: .vision,
            pages: pages,
            indexedAt: Date(),
            isTruncated: isTruncated
        )
    }
}

struct DocumentUnderstandingService: Sendable {
    func analyze(
        index: DocumentTextIndex,
        profile: DocumentProfile
    ) -> DocumentBrief {
        let indexedCharacterCount = index.characterCount
        let text = index.text
        let normalizedText = text.lowercased()
        let classification = classification(
            normalizedText: normalizedText,
            characterCount: indexedCharacterCount,
            profile: profile
        )
        let category = classification.category
        let entities = extractEntities(from: index)
        let steps = suggestedSteps(
            index: index,
            category: category,
            entities: entities,
            profile: profile,
            text: text,
            normalizedText: normalizedText
        )

        return DocumentBrief(
            category: category,
            summary: summary(
                category: category,
                confidence: classification.confidence,
                entities: entities,
                profile: profile,
                hasText: !text.isEmpty
            ),
            entities: Array(entities.prefix(24)),
            suggestedSteps: Array(steps.prefix(5)),
            indexedAt: index.indexedAt,
            textSource: index.source,
            indexedCharacterCount: indexedCharacterCount,
            confidence: classification.confidence
        )
    }

    private func classification(
        normalizedText: String,
        characterCount: Int,
        profile: DocumentProfile
    ) -> Classification {
        if profile.formFieldCount > 0 {
            return Classification(category: .form, confidence: .high)
        }

        let scores: [(DocumentCategory, Int)] = [
            (
                .invoice,
                keywordScore(
                    in: normalizedText,
                    keywords: ["invoice", "amount due", "bill to", "payment terms"]
                )
            ),
            (
                .receipt,
                keywordScore(
                    in: normalizedText,
                    keywords: ["receipt", "subtotal", "cashier", "change due"]
                )
            ),
            (
                .contract,
                keywordScore(
                    in: normalizedText,
                    keywords: [
                        "agreement",
                        "hereinafter",
                        "terms and conditions",
                        "signature",
                        "party"
                    ]
                )
            ),
            (
                .report,
                keywordScore(
                    in: normalizedText,
                    keywords: ["report", "executive summary", "findings", "methodology"]
                )
            ),
            (
                .letter,
                keywordScore(
                    in: normalizedText,
                    keywords: ["dear ", "sincerely", "to whom it may concern"]
                )
            )
        ]

        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            return Classification(
                category: .general,
                confidence: characterCount >= 500 ? .medium : .low
            )
        }
        let confidence: DocumentUnderstandingConfidence
        if best.1 >= 3 {
            confidence = .high
        } else if best.1 == 2 {
            confidence = .medium
        } else {
            confidence = .low
        }
        return Classification(
            category: best.0,
            confidence: confidence
        )
    }

    private func keywordScore(in text: String, keywords: [String]) -> Int {
        keywords.reduce(0) { partial, keyword in
            partial + (text.contains(keyword) ? 1 : 0)
        }
    }

    private func extractEntities(from index: DocumentTextIndex) -> [DetectedEntity] {
        var entities: [DetectedEntity] = []
        var seen: Set<String> = []
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
                | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
                | NSTextCheckingResult.CheckingType.date.rawValue
        )
        let expressionDefinitions: [(String, DetectedEntity.Kind)] = [
            (
                #"(?i)(?:USD|EUR|GBP|CNY|RMB|\$|€|£|¥)\s?\d[\d,.]*(?:\.\d{2})?"#,
                .amount
            ),
            (
                #"(?i)(?:invoice|order|reference|ref|account)\s*(?:no\.?|number|#|:)\s*[A-Z0-9][A-Z0-9._-]{2,}"#,
                .reference
            ),
            (
                #"(?i)(?:SSN|social security|tax id|passport|IBAN)\s*(?:no\.?|number|#|:)?\s*[A-Z0-9][A-Z0-9 -]{4,30}"#,
                .identifier
            )
        ]
        let expressions = expressionDefinitions.compactMap {
            pattern,
            kind -> (NSRegularExpression, DetectedEntity.Kind)? in
            guard let expression = try? NSRegularExpression(
                pattern: pattern
            ) else { return nil }
            return (expression, kind)
        }

        for page in index.pages {
            guard !Task.isCancelled else { break }
            let range = NSRange(page.text.startIndex..., in: page.text)
            if let detector {
                detector.enumerateMatches(
                    in: page.text,
                    options: [],
                    range: range
                ) { result, _, stop in
                    guard !Task.isCancelled else {
                        stop.pointee = true
                        return
                    }
                    guard let result,
                          let swiftRange = Range(result.range, in: page.text)
                    else { return }
                    let rawValue = String(page.text[swiftRange])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let kind: DetectedEntity.Kind
                    let value: String
                    if result.resultType == .phoneNumber {
                        kind = .phone
                        value = result.phoneNumber ?? rawValue
                    } else if result.resultType == .date {
                        kind = .date
                        value = rawValue
                    } else if result.url?.scheme?.lowercased() == "mailto" {
                        kind = .email
                        value = result.url?.absoluteString
                            .replacingOccurrences(of: "mailto:", with: "")
                            ?? rawValue
                    } else {
                        kind = .link
                        value = result.url?.absoluteString ?? rawValue
                    }
                    appendEntity(
                        kind: kind,
                        value: value,
                        pageIndex: page.pageIndex,
                        seen: &seen,
                        entities: &entities
                    )
                }
            }

            for (expression, kind) in expressions {
                appendRegexMatches(
                    expression: expression,
                    kind: kind,
                    page: page,
                    seen: &seen,
                    entities: &entities
                )
            }
        }

        return entities
    }

    private func appendRegexMatches(
        expression: NSRegularExpression,
        kind: DetectedEntity.Kind,
        page: IndexedPageText,
        seen: inout Set<String>,
        entities: inout [DetectedEntity]
    ) {
        let range = NSRange(page.text.startIndex..., in: page.text)
        for match in expression.matches(in: page.text, range: range) {
            guard !Task.isCancelled else { break }
            guard let swiftRange = Range(match.range, in: page.text) else { continue }
            appendEntity(
                kind: kind,
                value: String(page.text[swiftRange]),
                pageIndex: page.pageIndex,
                seen: &seen,
                entities: &entities
            )
        }
    }

    private func appendEntity(
        kind: DetectedEntity.Kind,
        value: String,
        pageIndex: Int,
        seen: inout Set<String>,
        entities: inout [DetectedEntity]
    ) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let key = "\(kind.rawValue):\(cleaned.lowercased())"
        guard seen.insert(key).inserted else { return }
        entities.append(
            DetectedEntity(
                kind: kind,
                value: String(cleaned.prefix(160)),
                pageIndex: pageIndex
            )
        )
    }

    private func suggestedSteps(
        index: DocumentTextIndex,
        category: DocumentCategory,
        entities: [DetectedEntity],
        profile: DocumentProfile,
        text: String,
        normalizedText: String
    ) -> [SuggestedStep] {
        var steps: [SuggestedStep] = []

        if text.isEmpty && (profile.kind == .scan || profile.kind == .mixed) {
            steps.append(
                SuggestedStep(
                    kind: .recognize,
                    title: "Recognize document text",
                    evidence: "Image-based pages do not contain searchable text."
                )
            )
        }
        if profile.formFieldCount > 0 {
            steps.append(
                SuggestedStep(
                    kind: .completeForm,
                    title: "Review \(profile.formFieldCount) form field\(profile.formFieldCount == 1 ? "" : "s")",
                    evidence: "Interactive fields were found in the PDF structure.",
                    evidencePageIndex: 0
                )
            )
        }
        if normalizedText.contains("signature")
            || normalizedText.contains("sign here")
            || normalizedText.contains("signed by") {
            let evidence = firstEvidence(
                in: index,
                matching: ["signature", "sign here", "signed by"]
            )
            steps.append(
                SuggestedStep(
                    kind: .reviewSignature,
                    title: "Review signature requirement",
                    evidence: evidence.text,
                    evidencePageIndex: evidence.pageIndex
                )
            )
        }
        if let date = entities.first(where: { $0.kind == .date }) {
            steps.append(
                SuggestedStep(
                    kind: .reviewDate,
                    title: "Check the detected date",
                    evidence: date.value,
                    evidencePageIndex: date.pageIndex
                )
            )
        }
        if (category == .invoice || category == .receipt),
           let amount = entities.first(where: { $0.kind == .amount }) {
            steps.append(
                SuggestedStep(
                    kind: .reviewAmount,
                    title: "Verify the detected amount",
                    evidence: amount.value,
                    evidencePageIndex: amount.pageIndex
                )
            )
        }
        if profile.pageCount >= 8 {
            steps.append(
                SuggestedStep(
                    kind: .organize,
                    title: "Review page order",
                    evidence: "This working copy contains \(profile.pageCount) pages."
                )
            )
        }

        return steps
    }

    private func firstEvidence(
        in index: DocumentTextIndex,
        matching terms: [String]
    ) -> Evidence {
        for page in index.pages {
            guard !Task.isCancelled else { break }
            let lines = page.text.components(separatedBy: .newlines)
            for line in lines {
                guard !Task.isCancelled else { break }
                let normalized = line.lowercased()
                if terms.contains(where: normalized.contains) {
                    return Evidence(
                        text: String(
                            line.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).prefix(180)
                        ),
                        pageIndex: page.pageIndex
                    )
                }
            }
        }
        return Evidence(
            text: "Signature-related language was detected.",
            pageIndex: nil
        )
    }

    private func summary(
        category: DocumentCategory,
        confidence: DocumentUnderstandingConfidence,
        entities: [DetectedEntity],
        profile: DocumentProfile,
        hasText: Bool
    ) -> String {
        guard hasText else {
            return AppLocalization.format(
                "Image-based document with %lld pages. Run Recognize Text to search it.",
                profile.pageCount
            )
        }
        let factCount = entities.count
        if category == .general {
            return factCount == 0
                ? "Text is indexed locally and ready for private search."
                : "Text is indexed locally with \(factCount) detected fact\(factCount == 1 ? "" : "s") to review."
        }
        let prefix: String
        switch confidence {
        case .high: prefix = category.title
        case .medium: prefix = "Likely \(category.title.lowercased())"
        case .low: prefix = "Possible \(category.title.lowercased())"
        }
        return "\(prefix) with \(factCount) detected fact\(factCount == 1 ? "" : "s"). Review the evidence before acting."
    }

    private struct Classification {
        let category: DocumentCategory
        let confidence: DocumentUnderstandingConfidence
    }

    private struct Evidence {
        let text: String
        let pageIndex: Int?
    }
}
