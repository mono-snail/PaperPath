import CryptoKit
import Foundation
import PDFKit
import UIKit
@preconcurrency import Vision

struct PDFDeliveryAuditService: @unchecked Sendable {
    func preflight(
        sourceURL: URL
    ) throws -> PDFDeliveryPreflightAssessment {
        try Task.checkCancellation()

        guard let document = PDFDocument(url: sourceURL),
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }

        let size = try fileSize(at: sourceURL)
        if document.isLocked {
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
                        status: .blocked
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
                reviewPageIndex: blankPages.first
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

        return PDFDeliveryPreflightAssessment(
            status: status,
            pageCount: snapshot.pageCount,
            byteCount: size,
            fixCount: fixCount,
            reviewCount: reviewCount,
            items: items
        )
    }

    func compare(
        sourceURL: URL,
        revisedURL: URL
    ) throws -> PDFChangeReview {
        try Task.checkCancellation()
        guard let sourceDocument = PDFDocument(url: sourceURL),
              let revisedDocument = PDFDocument(url: revisedURL),
              !sourceDocument.isLocked,
              !revisedDocument.isLocked,
              sourceDocument.pageCount > 0,
              revisedDocument.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        let sourceSnapshot = try snapshot(
            of: sourceDocument,
            options: .comparison(
                pageCount: sourceDocument.pageCount
            )
        )
        try Task.checkCancellation()
        let revisedSnapshot = try snapshot(
            of: revisedDocument,
            options: .comparison(
                pageCount: revisedDocument.pageCount
            )
        )
        return try changeReview(
            source: sourceSnapshot,
            revised: revisedSnapshot
        )
    }

    func audit(
        sourceURL: URL,
        outputURL: URL,
        operation: PDFDeliveryOperation,
        unlockPassword: String? = nil
    ) throws -> PDFDeliveryReceipt {
        try Task.checkCancellation()

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

        let sourceSnapshot = try snapshot(
            of: sourceDocument,
            options: .comparison(
                pageCount: sourceDocument.pageCount
            )
        )
        let outputSnapshot = try snapshot(
            of: outputDocument,
            options: .comparison(
                pageCount: outputDocument.pageCount
            )
        )
        let outputChangeReview = try changeReview(
            source: sourceSnapshot,
            revised: outputSnapshot
        )
        let sourceSize = try fileSize(at: sourceURL)
        let outputSize = try fileSize(at: outputURL)
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

        if let failed = checks.first(where: { $0.status == .failed }) {
            throw PaperPathError.outputVerificationFailed(failed.detail)
        }

        return PDFDeliveryReceipt(
            id: UUID(),
            operation: operation,
            createdAt: Date(
                timeIntervalSince1970: floor(
                    Date().timeIntervalSince1970
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
        options: SnapshotOptions = .complete
    ) throws -> Snapshot {
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
            let pageSnapshot: PageSnapshot = autoreleasepool {
                guard let page = document.page(at: index) else {
                    return .empty
                }
                let annotations = page.annotations.count
                let rawPageText = page.string ?? ""
                let pageText = normalizedText(rawPageText)
                let characters = pageText.count
                let textFingerprint = Data(
                    SHA256.hash(data: Data(pageText.utf8))
                )
                let bounds = page.bounds(for: .cropBox)
                guard bounds.width.isFinite,
                      bounds.height.isFinite,
                      bounds.width > 0,
                      bounds.height > 0
                else {
                    return PageSnapshot(
                        rendered: false,
                        coverage: 0,
                        annotationCount: annotations,
                        textCharacterCount: characters,
                        textFingerprint: textFingerprint,
                        textFragments: [],
                        pageLabelFingerprint: nil,
                        stableMarkerFingerprint: nil,
                        barcodeFingerprint: nil,
                        pageSize: bounds.size,
                        rotation: page.rotation,
                        visualSamples: []
                    )
                }
                let textFragments = textFragments(
                    in: page,
                    text: rawPageText,
                    pageBounds: bounds,
                    limit: options.maximumTextFragments
                )
                let pageLabelFingerprint = pageLabelFingerprint(
                    page.label,
                    pageIndex: index
                )
                let stableMarkerFingerprint = stableMarkerFingerprint(
                    textFragments
                )
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
                        visualSamples: []
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
                      let visual = visualSignature(of: image)
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
                        visualSamples: []
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
                    visualSamples: visual.samples
                )
            }
            try Task.checkCancellation()
            annotationCount += pageSnapshot.annotationCount
            textCharacterCount += pageSnapshot.textCharacterCount
            if pageSnapshot.rendered {
                renderedPageCount += 1
                renderedPageIndices.append(index)
            }
            coverage.append(pageSnapshot.coverage)
            pageSnapshots.append(pageSnapshot)
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
        of image: UIImage
    ) -> VisualSignature? {
        guard let source = image.cgImage else { return nil }
        let width = 48
        let height = 48
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
            let darkest = min(red, green, blue)
            let lightest = max(red, green, blue)
            if darkest < 242 || lightest - darkest > 10 {
                contentPixels += 1
            }
        }
        return VisualSignature(
            coverage: Double(contentPixels) / Double(totalPixels),
            samples: samples
        )
    }

    private func normalizedText(_ value: String) -> String {
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

    private func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private func comparisonToken(_ value: String) -> String {
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

    private func normalizedRegion(
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

    private func pageLabelFingerprint(
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

    private func stableMarkerFingerprint(
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

    private func changeReview(
        source: Snapshot,
        revised: Snapshot
    ) throws -> PDFChangeReview {
        try Task.checkCancellation()
        let aligned = try alignedPages(
            source: source.pages,
            revised: revised.pages
        )
        var changes: [PDFPageChange] = []
        var pageMatches: [PDFPageMatch] = []
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
            let change = pageChange(
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
        }

        return PDFChangeReview(
            sourcePageCount: source.pageCount,
            revisedPageCount: revised.pageCount,
            comparedPageCount: aligned.filter {
                $0.sourceIndex != nil && $0.revisedIndex != nil
            }.count,
            changes: changes,
            pageMatches: pageMatches
        )
    }

    private func pageChange(
        sequenceIndex: Int,
        sourceIndex: Int?,
        revisedIndex: Int?,
        source: PageSnapshot?,
        revised: PageSnapshot?,
        matchBasis: PDFPageMatchBasis?
    ) -> PDFPageChange? {
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
        let visual = visualDifference(
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
            : (source: [], revised: [])
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
            differenceRegions: differenceRegions(
                source.visualSamples,
                revised.visualSamples
            ),
            sourceTextDifferences: textDifferences.source,
            revisedTextDifferences: textDifferences.revised,
            matchBasis: matchBasis
        )
        return candidate.isVisibleChange || candidate.textChanged
            ? candidate
            : nil
    }

    private func alignedPages(
        source: [PageSnapshot],
        revised: [PageSnapshot]
    ) throws -> [AlignedPage] {
        try Task.checkCancellation()
        let anchors = stableAnchors(
            source: source,
            revised: revised
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

    private func stableAnchors(
        source: [PageSnapshot],
        revised: [PageSnapshot]
    ) -> [AnchorCandidate] {
        let sourceKeys = source.map(pageAnchorKey)
        let revisedKeys = revised.map(pageAnchorKey)
        let sourceExact = uniqueKeyIndices(sourceKeys)
        let revisedExact = uniqueKeyIndices(revisedKeys)
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
        var occupiedSource = Set(candidates.map(\.source))
        var occupiedRevised = Set(candidates.map(\.revised))

        appendUniqueAnchors(
            sourceKeys: source.map(\.pageLabelFingerprint),
            revisedKeys: revised.map(\.pageLabelFingerprint),
            basis: .pageLabel,
            candidates: &candidates,
            occupiedSource: &occupiedSource,
            occupiedRevised: &occupiedRevised
        )
        appendUniqueAnchors(
            sourceKeys: source.map(\.stableMarkerFingerprint),
            revisedKeys: revised.map(\.stableMarkerFingerprint),
            basis: .textMarker,
            candidates: &candidates,
            occupiedSource: &occupiedSource,
            occupiedRevised: &occupiedRevised
        )
        appendUniqueAnchors(
            sourceKeys: source.map(\.barcodeFingerprint),
            revisedKeys: revised.map(\.barcodeFingerprint),
            basis: .barcode,
            candidates: &candidates,
            occupiedSource: &occupiedSource,
            occupiedRevised: &occupiedRevised
        )
        let sourceContext = contextualAnchorKeys(
            pages: source,
            keys: sourceKeys
        )
        let revisedContext = contextualAnchorKeys(
            pages: revised,
            keys: revisedKeys
        )
        let sourceContextUnique = uniqueKeyIndices(sourceContext)
        let revisedContextUnique = uniqueKeyIndices(revisedContext)
        for (key, sourceIndex) in sourceContextUnique {
            guard !occupiedSource.contains(sourceIndex),
                  let revisedIndex = revisedContextUnique[key],
                  !occupiedRevised.contains(revisedIndex)
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
        return longestIncreasingAnchors(candidates)
    }

    private func appendUniqueAnchors(
        sourceKeys: [Data?],
        revisedKeys: [Data?],
        basis: PDFPageMatchBasis,
        candidates: inout [AnchorCandidate],
        occupiedSource: inout Set<Int>,
        occupiedRevised: inout Set<Int>
    ) {
        let sourceUnique = uniqueKeyIndices(sourceKeys)
        let revisedUnique = uniqueKeyIndices(revisedKeys)
        for (key, sourceIndex) in sourceUnique {
            guard !occupiedSource.contains(sourceIndex),
                  let revisedIndex = revisedUnique[key],
                  !occupiedRevised.contains(revisedIndex)
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

    private func uniqueKeyIndices(
        _ keys: [Data?]
    ) -> [Data: Int] {
        let grouped = Dictionary(
            grouping: keys.enumerated().compactMap {
                index,
                key in
                key.map { ($0, index) }
            },
            by: \.0
        )
        return grouped.reduce(into: [:]) { result, entry in
            guard entry.value.count == 1,
                  let index = entry.value.first?.1
            else { return }
            result[entry.key] = index
        }
    }

    private func contextualAnchorKeys(
        pages: [PageSnapshot],
        keys: [Data?]
    ) -> [Data?] {
        guard pages.count == keys.count else {
            return Array(repeating: nil, count: pages.count)
        }
        var groups: [(key: Data, indices: [Int])] = []
        groups.reserveCapacity(keys.count)
        for (index, key) in keys.enumerated() {
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

    private func pageAnchorKey(
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

    private func longestIncreasingAnchors(
        _ candidates: [AnchorCandidate]
    ) -> [AnchorCandidate] {
        guard !candidates.isEmpty else { return [] }
        var tails: [Int] = []
        var tailCandidateIndices: [Int] = []
        var predecessors = Array(
            repeating: -1,
            count: candidates.count
        )

        for (candidateIndex, candidate) in candidates.enumerated() {
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
        while index >= 0 {
            result.append(candidates[index])
            index = predecessors[index]
        }
        return result.reversed()
    }

    private func alignSegment(
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
        guard sourceIndices.count * revisedIndices.count <= 250_000
        else {
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

    private func locatedTextDifferences(
        source: [TextFragment],
        revised: [TextFragment]
    ) -> (
        source: [PDFTextDifferenceEvidence],
        revised: [PDFTextDifferenceEvidence]
    ) {
        guard !source.isEmpty || !revised.isEmpty else {
            return ([], [])
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
        var removed: [PDFTextDifferenceEvidence] = []
        var inserted: [PDFTextDifferenceEvidence] = []

        for (removedOffset, insertedOffset) in zip(
            sortedRemoved,
            sortedInserted
        ) {
            guard abs(removedOffset - insertedOffset) <= 2,
                  source.indices.contains(removedOffset),
                  revised.indices.contains(insertedOffset),
                  let refined = refinedCharacterDifferences(
                    source: source[removedOffset],
                    revised: revised[insertedOffset]
                  )
            else { continue }
            pairedRemoved.insert(removedOffset)
            pairedInserted.insert(insertedOffset)
            if let evidence = refined.source {
                removed.append(evidence)
            }
            if let evidence = refined.revised {
                inserted.append(evidence)
            }
        }

        for offset in sortedRemoved
            where !pairedRemoved.contains(offset)
                && removed.count < 24 {
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
        for offset in sortedInserted
            where !pairedInserted.contains(offset)
                && inserted.count < 24 {
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
            Array(removed.prefix(24)),
            Array(inserted.prefix(24))
        )
    }

    private func refinedCharacterDifferences(
        source: TextFragment,
        revised: TextFragment
    ) -> (
        source: PDFTextDifferenceEvidence?,
        revised: PDFTextDifferenceEvidence?
    )? {
        let sourceCharacters = source.characters
        let revisedCharacters = revised.characters
        guard !sourceCharacters.isEmpty,
              !revisedCharacters.isEmpty
        else { return nil }

        var prefixCount = 0
        while prefixCount < sourceCharacters.count,
              prefixCount < revisedCharacters.count,
              sourceCharacters[prefixCount].text
                == revisedCharacters[prefixCount].text {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount
                < sourceCharacters.count - prefixCount,
              suffixCount
                < revisedCharacters.count - prefixCount,
              sourceCharacters[
                sourceCharacters.count - suffixCount - 1
              ].text
                == revisedCharacters[
                    revisedCharacters.count - suffixCount - 1
                ].text {
            suffixCount += 1
        }

        let sourceEnd = sourceCharacters.count - suffixCount
        let revisedEnd = revisedCharacters.count - suffixCount
        let sourceChanged = Array(
            sourceCharacters[prefixCount..<sourceEnd]
        )
        let revisedChanged = Array(
            revisedCharacters[prefixCount..<revisedEnd]
        )
        guard !sourceChanged.isEmpty || !revisedChanged.isEmpty,
              sourceChanged.count < sourceCharacters.count
                || revisedChanged.count < revisedCharacters.count
        else { return nil }

        let sourceEvidence = characterEvidence(
            sourceChanged,
            kind: .removed
        )
        let revisedEvidence = characterEvidence(
            revisedChanged,
            kind: .inserted
        )
        guard sourceEvidence != nil || revisedEvidence != nil else {
            return nil
        }
        return (sourceEvidence, revisedEvidence)
    }

    private func characterEvidence(
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

    private func union(
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

    private func pageSimilarityScore(
        _ source: PageSnapshot,
        _ revised: PageSnapshot
    ) -> Double {
        if source.textCharacterCount >= 8,
           source.textFingerprint == revised.textFingerprint {
            return 6
        }
        let visual = visualDifference(
            source.visualSamples,
            revised.visualSamples
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

    private func differenceRegions(
        _ source: [UInt8],
        _ revised: [UInt8]
    ) -> [PDFDifferenceRegion]? {
        let side = 48
        let channels = 3
        guard source.count == side * side * channels,
              revised.count == source.count
        else { return nil }
        let grid = 6
        let cellSide = side / grid
        var regions: [PDFDifferenceRegion] = []
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
                        if delta >= 8 {
                            changed += 1
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
        return Array(
            regions.sorted {
                $0.intensity > $1.intensity
            }.prefix(12)
        )
    }

    private func pageGeometryChanged(
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

    private func visualDifference(
        _ source: [UInt8],
        _ revised: [UInt8]
    ) -> (
        meanDifference: Double,
        changedPixelRatio: Double
    ) {
        guard source.count == revised.count,
              !source.isEmpty,
              source.count.isMultiple(of: 3)
        else {
            return (1, 1)
        }
        var totalDifference = 0
        var changedPixels = 0
        let pixelCount = source.count / 3
        for offset in stride(from: 0, to: source.count, by: 3) {
            let red = abs(Int(source[offset]) - Int(revised[offset]))
            let green = abs(
                Int(source[offset + 1]) - Int(revised[offset + 1])
            )
            let blue = abs(
                Int(source[offset + 2]) - Int(revised[offset + 2])
            )
            totalDifference += red + green + blue
            if max(red, green, blue) >= 8 {
                changedPixels += 1
            }
        }
        return (
            Double(totalDifference) / Double(pixelCount * 255 * 3),
            Double(changedPixels) / Double(pixelCount)
        )
    }

    private func changeReviewCheck(
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

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
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

    private func pageList(_ zeroBasedPages: [Int]) -> String {
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

    private struct SnapshotOptions {
        static let complete = SnapshotOptions(
            renderedPageIndices: nil,
            renderLongestEdge: 160,
            maximumTextFragments: 160,
            detectBarcodes: false
        )

        let renderedPageIndices: Set<Int>?
        let renderLongestEdge: CGFloat
        let maximumTextFragments: Int
        let detectBarcodes: Bool

        static func preflight(pageCount: Int) -> SnapshotOptions {
            let maximumRenderedPages = 24
            guard pageCount > maximumRenderedPages else {
                return .complete
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
                detectBarcodes: false
            )
        }

        static func comparison(pageCount: Int) -> SnapshotOptions {
            SnapshotOptions(
                renderedPageIndices: nil,
                renderLongestEdge: pageCount > 300
                    ? 96
                    : pageCount > 120
                        ? 128
                        : 160,
                maximumTextFragments: pageCount > 300
                    ? 80
                    : pageCount > 120
                        ? 160
                        : 320,
                detectBarcodes: pageCount <= 200
            )
        }

        func shouldRender(pageIndex: Int) -> Bool {
            renderedPageIndices?.contains(pageIndex) ?? true
        }
    }

    private struct Snapshot {
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

    private struct PageSnapshot {
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
        let visualSamples: [UInt8]

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
            visualSamples: []
        )
    }

    private struct VisualSignature {
        let coverage: Double
        let samples: [UInt8]
    }

    private struct TextFragment {
        let text: String
        let normalized: String
        let comparison: String
        let region: PDFDifferenceRegion
        let characters: [CharacterFragment]
    }

    private struct CharacterFragment {
        let text: String
        let region: PDFDifferenceRegion
    }

    private struct AnchorCandidate {
        let source: Int
        let revised: Int
        let basis: PDFPageMatchBasis
    }

    private struct AlignedPage {
        let sourceIndex: Int?
        let revisedIndex: Int?
        let basis: PDFPageMatchBasis?
    }
}
