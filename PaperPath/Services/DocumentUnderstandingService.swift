import Foundation
import PDFKit

struct IndexedPageText: Codable, Hashable, Sendable {
    let pageIndex: Int
    let text: String
}

struct DocumentTextMatch: Hashable, Sendable {
    let pageIndex: Int
    let excerpt: String
}

struct DocumentTextIndex: Codable, Hashable, Sendable {
    let source: IndexedTextSource
    let pages: [IndexedPageText]
    let indexedAt: Date

    var text: String {
        pages.map(\.text).joined(separator: "\n\n")
    }

    var characterCount: Int {
        pages.reduce(0) { $0 + $1.text.count }
    }

    func segment(
        from startPageIndex: Int,
        through endPageIndex: Int
    ) -> DocumentTextIndex {
        DocumentTextIndex(
            source: source,
            pages: pages.compactMap { page in
                guard page.pageIndex >= startPageIndex,
                      page.pageIndex <= endPageIndex
                else { return nil }
                return IndexedPageText(
                    pageIndex: page.pageIndex - startPageIndex,
                    text: page.text
                )
            },
            indexedAt: indexedAt
        )
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
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0) }
        guard !terms.isEmpty, limit > 0 else { return [] }
        return pages.lazy.filter {
            terms.allSatisfy($0.text.localizedCaseInsensitiveContains)
        }
        .prefix(limit)
        .compactMap {
            match(
                page: $0,
                terms: terms,
                excerptLimit: excerptLimit
            )
        }
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
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        }.min {
            $0.lowerBound < $1.lowerBound
        }
        let matchOffset = firstRange.map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
        } ?? 0
        let limit = max(48, excerptLimit)
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
    private let maximumCharacterCount = 500_000

    func extractNativeText(from url: URL) throws -> DocumentTextIndex {
        guard let document = PDFDocument(url: url) else {
            throw PaperPathError.unreadablePDF
        }
        guard !document.isLocked else {
            throw PaperPathError.lockedPDF
        }

        var remaining = maximumCharacterCount
        var pages: [IndexedPageText] = []
        for pageIndex in 0..<document.pageCount where remaining > 0 {
            try Task.checkCancellation()
            guard let text = document.page(at: pageIndex)?.string else { continue }
            let normalized = text
                .replacingOccurrences(of: "\u{00a0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let pageText = String(normalized.prefix(remaining))
            pages.append(IndexedPageText(pageIndex: pageIndex, text: pageText))
            remaining -= pageText.count
        }

        return DocumentTextIndex(
            source: .native,
            pages: pages,
            indexedAt: Date()
        )
    }

    func index(from result: OCRResult) -> DocumentTextIndex {
        var pages: [IndexedPageText] = []
        pages.reserveCapacity(result.pages.count)
        for page in result.pages {
            guard !Task.isCancelled else { break }
            pages.append(
                IndexedPageText(
                    pageIndex: page.pageIndex,
                    text: page.text
                )
            )
        }
        return DocumentTextIndex(
            source: .vision,
            pages: pages,
            indexedAt: Date()
        )
    }
}

struct DocumentUnderstandingService: Sendable {
    func analyze(
        index: DocumentTextIndex,
        profile: DocumentProfile
    ) -> DocumentBrief {
        let text = index.text
        let classification = classification(
            for: text,
            profile: profile
        )
        let category = classification.category
        let entities = extractEntities(from: index)
        let steps = suggestedSteps(
            index: index,
            category: category,
            entities: entities,
            profile: profile
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
            indexedCharacterCount: index.characterCount,
            confidence: classification.confidence
        )
    }

    private func classification(
        for text: String,
        profile: DocumentProfile
    ) -> Classification {
        if profile.formFieldCount > 0 {
            return Classification(category: .form, confidence: .high)
        }

        let normalized = text.lowercased()
        let scores: [(DocumentCategory, Int)] = [
            (
                .invoice,
                keywordScore(
                    in: normalized,
                    keywords: ["invoice", "amount due", "bill to", "payment terms"]
                )
            ),
            (
                .receipt,
                keywordScore(
                    in: normalized,
                    keywords: ["receipt", "subtotal", "cashier", "change due"]
                )
            ),
            (
                .contract,
                keywordScore(
                    in: normalized,
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
                    in: normalized,
                    keywords: ["report", "executive summary", "findings", "methodology"]
                )
            ),
            (
                .letter,
                keywordScore(
                    in: normalized,
                    keywords: ["dear ", "sincerely", "to whom it may concern"]
                )
            )
        ]

        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            return Classification(
                category: .general,
                confidence: text.count >= 500 ? .medium : .low
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

        for page in index.pages {
            guard !Task.isCancelled else { break }
            let range = NSRange(page.text.startIndex..., in: page.text)
            if let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
                    | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
                    | NSTextCheckingResult.CheckingType.date.rawValue
            ) {
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

            appendRegexMatches(
                pattern: #"(?i)(?:USD|EUR|GBP|CNY|RMB|\$|€|£|¥)\s?\d[\d,.]*(?:\.\d{2})?"#,
                kind: .amount,
                page: page,
                seen: &seen,
                entities: &entities
            )
            appendRegexMatches(
                pattern: #"(?i)(?:invoice|order|reference|ref|account)\s*(?:no\.?|number|#|:)\s*[A-Z0-9][A-Z0-9._-]{2,}"#,
                kind: .reference,
                page: page,
                seen: &seen,
                entities: &entities
            )
            appendRegexMatches(
                pattern: #"(?i)(?:SSN|social security|tax id|passport|IBAN)\s*(?:no\.?|number|#|:)?\s*[A-Z0-9][A-Z0-9 -]{4,30}"#,
                kind: .identifier,
                page: page,
                seen: &seen,
                entities: &entities
            )
        }

        return entities
    }

    private func appendRegexMatches(
        pattern: String,
        kind: DetectedEntity.Kind,
        page: IndexedPageText,
        seen: inout Set<String>,
        entities: inout [DetectedEntity]
    ) {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: []
        ) else { return }
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
        profile: DocumentProfile
    ) -> [SuggestedStep] {
        var steps: [SuggestedStep] = []
        let text = index.text
        let normalized = text.lowercased()

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
        if normalized.contains("signature")
            || normalized.contains("sign here")
            || normalized.contains("signed by") {
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
            return "A \(profile.pageCount)-page image-based document. Recognize text to reveal facts and make it searchable."
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
