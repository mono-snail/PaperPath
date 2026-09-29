import CoreGraphics
import Darwin
import Foundation
import PDFKit

struct PDFInspectionService {
    private let maximumSampledPages = 12
    private let maximumPageCount = 100_000
    private let maximumAnnotationsPerPage = 4_096
    private let maximumFormFieldCount = 100_000
    private let imageDominantCharacterThreshold = 24
    private let minimumSparseHoleBytes: Int64 = 8 * 1_024 * 1_024
    private let maximumSparseStructureBytes = 32 * 1_024 * 1_024

    func inspect(
        url: URL,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> DocumentProfile {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: url) else {
            throw PaperPathError.unreadablePDF
        }

        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0

        guard document.pageCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Inspect PDFs with up to 100,000 pages."
            )
        }
        if document.isLocked {
            progress(document.pageCount, document.pageCount)
            return DocumentProfile(
                pageCount: document.pageCount,
                sampledPageCount: 0,
                textCharacterCount: 0,
                imageDominantPageCount: 0,
                formFieldCount: 0,
                byteCount: byteCount,
                isEncrypted: document.isEncrypted,
                isLocked: true,
                allowsCopying: document.allowsCopying,
                allowsCommenting: document.allowsCommenting,
                kind: .protected,
                recommendedActions: [.inspect, .shareCopy]
            )
        }

        progress(0, document.pageCount)
        let sampleIndices = sampledIndices(pageCount: document.pageCount)
        let sampledIndexSet = Set(sampleIndices)
        let reportingStride = inspectionReportingStride(
            pageCount: document.pageCount
        )
        var textCharacterCount = 0
        var imageDominantPageCount = 0
        var formFieldCount = 0

        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw PaperPathError.invalidPage
            }
            let metrics = try autoreleasepool {
                () throws -> (fieldCount: Int, textCount: Int?) in
                let annotations = page.annotations
                guard annotations.count <= maximumAnnotationsPerPage
                else {
                    throw PaperPathError.insufficientSelection(
                        "A PDF page contains too many annotations to inspect safely."
                    )
                }
                var pageFieldCount = 0
                for (offset, annotation) in annotations.enumerated() {
                    if offset.isMultiple(of: 64) {
                        try Task.checkCancellation()
                    }
                    if PDFFormInspectionService().isWidget(annotation) {
                        pageFieldCount += 1
                    }
                }
                let textCount = sampledIndexSet.contains(index)
                    ? page.string?
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        .count ?? 0
                    : nil
                return (pageFieldCount, textCount)
            }
            let (nextFieldCount, overflow) = formFieldCount
                .addingReportingOverflow(metrics.fieldCount)
            guard !overflow,
                  nextFieldCount <= maximumFormFieldCount
            else {
                throw PaperPathError.insufficientSelection(
                    "This PDF contains too many form fields to inspect safely."
                )
            }
            formFieldCount = nextFieldCount
            if let textCount = metrics.textCount {
                let (nextTextCount, textOverflow) =
                    textCharacterCount.addingReportingOverflow(
                        textCount
                    )
                guard !textOverflow else {
                    throw PaperPathError.insufficientSelection(
                        "This PDF contains too much text to inspect safely."
                    )
                }
                textCharacterCount = nextTextCount
                if textCount < imageDominantCharacterThreshold {
                    imageDominantPageCount += 1
                }
            }
            let completedPageCount = index + 1
            if completedPageCount.isMultiple(of: reportingStride)
                || completedPageCount == document.pageCount {
                progress(completedPageCount, document.pageCount)
            }
        }

        let kind = classify(
            sampledPageCount: sampleIndices.count,
            imageDominantPageCount: imageDominantPageCount,
            formFieldCount: formFieldCount,
            isEncrypted: document.isEncrypted,
            allowsCopying: document.allowsCopying,
            allowsCommenting: document.allowsCommenting
        )
        let actions = recommendations(
            kind: kind,
            pageCount: document.pageCount,
            isLocked: false
        )

        return DocumentProfile(
            pageCount: document.pageCount,
            sampledPageCount: sampleIndices.count,
            textCharacterCount: textCharacterCount,
            imageDominantPageCount: imageDominantPageCount,
            formFieldCount: formFieldCount,
            byteCount: byteCount,
            isEncrypted: document.isEncrypted,
            isLocked: false,
            allowsCopying: document.allowsCopying,
            allowsCommenting: document.allowsCommenting,
            kind: kind,
            recommendedActions: actions
        )
    }

    func inspectMetadataOnly(
        url: URL,
        byteCount: Int64,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> DocumentProfile {
        try Task.checkCancellation()
        guard byteCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        if let sparseProfile = try inspectSparseMetadata(
            url: url,
            byteCount: byteCount,
            progress: progress
        ) {
            return sparseProfile
        }
        guard let document = CGPDFDocument(url as CFURL),
              document.numberOfPages > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        guard document.numberOfPages <= maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Inspect PDFs with up to 100,000 pages."
            )
        }

        let isEncrypted = document.isEncrypted
        let isLocked = isEncrypted
            && !document.isUnlocked
        let allowsCopying = !isLocked
            && document.allowsCopying
        if isLocked {
            progress(document.numberOfPages, document.numberOfPages)
            return DocumentProfile(
                pageCount: document.numberOfPages,
                sampledPageCount: 0,
                textCharacterCount: 0,
                imageDominantPageCount: 0,
                formFieldCount: 0,
                byteCount: byteCount,
                isEncrypted: true,
                isLocked: true,
                allowsCopying: false,
                allowsCommenting: false,
                kind: .protected,
                recommendedActions: [.inspect, .shareCopy]
            )
        }

        progress(0, document.numberOfPages)
        let formFieldCount = try countFormFields(
            in: document,
            progress: progress
        )
        let allowsCommenting = !isEncrypted
        let kind: DocumentKind
        if isEncrypted || !allowsCopying || !allowsCommenting {
            kind = .protected
        } else if formFieldCount > 0 {
            kind = .form
        } else {
            // Content streams remain unopened on the bounded path.
            kind = .mixed
        }
        return DocumentProfile(
            pageCount: document.numberOfPages,
            sampledPageCount: 0,
            textCharacterCount: 0,
            imageDominantPageCount: 0,
            formFieldCount: formFieldCount,
            byteCount: byteCount,
            isEncrypted: isEncrypted,
            isLocked: false,
            allowsCopying: allowsCopying,
            allowsCommenting: allowsCommenting,
            kind: kind,
            recommendedActions: recommendations(
                kind: kind,
                pageCount: document.numberOfPages,
                isLocked: false
            )
        )
    }

    private func inspectSparseMetadata(
        url: URL,
        byteCount: Int64,
        progress: @Sendable (Int, Int) -> Void
    ) throws -> DocumentProfile? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw PaperPathError.unreadablePDF
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size == byteCount else {
            throw PaperPathError.unreadablePDF
        }
        let allocatedByteCount = min(
            byteCount,
            Int64(status.st_blocks) * 512
        )
        guard byteCount - allocatedByteCount
            >= minimumSparseHoleBytes else {
            return nil
        }

        let structure = try sparseStructureData(
            descriptor: descriptor,
            byteCount: byteCount
        )
        let text = try sparseMetadataText(
            from: String(decoding: structure, as: UTF8.self)
        )
        let structuralText = try sparseStructuralText(from: text)
        let trailerBodies = sparseTrailerBodies(in: structuralText)
        guard sparseHeaderIsValid(in: text),
              sparseFooterIsValid(in: text),
              let rootReference = trailerBodies.reversed()
                .compactMap({
                    pdfIndirectReference(
                        for: "Root",
                        in: $0
                    )
                })
                .first,
              let catalogBody = sparseObjectBody(
                objectNumber: rootReference.objectNumber,
                generationNumber: rootReference.generationNumber,
                in: structuralText
              ),
              containsPDFNamePair(
                key: "Type",
                value: "Catalog",
                in: catalogBody
              ),
              let pagesReference = pdfIndirectReference(
                for: "Pages",
                in: catalogBody
              ),
              let pagesBody = sparseObjectBody(
                objectNumber: pagesReference.objectNumber,
                generationNumber: pagesReference.generationNumber,
                in: structuralText
              ),
              containsPDFNamePair(
                key: "Type",
                value: "Pages",
                in: pagesBody
              ),
              let pageCount = pdfInteger(
                for: "Count",
                in: pagesBody
              ),
              pageCount > 0,
              pageCount <= maximumPageCount else {
            throw PaperPathError.unreadablePDF
        }

        let isEncrypted = trailerBodies.contains {
            containsPDFToken(
                "/Encrypt",
                in: $0
            )
        }
        let hasAcroForm = containsPDFToken(
            "/AcroForm",
            in: catalogBody
        )
        let detectedFormFieldCount = hasAcroForm
            ? pdfTokenCount(
                pattern: #"/Subtype\s*/Widget\b"#,
                in: structuralText
            )
            : 0
        guard detectedFormFieldCount <= maximumFormFieldCount else {
            throw PaperPathError.insufficientSelection(
                "This PDF contains too many form fields to inspect safely."
            )
        }
        let formFieldCount = detectedFormFieldCount
        let kind: DocumentKind
        if isEncrypted {
            kind = .protected
        } else if formFieldCount > 0 {
            kind = .form
        } else {
            kind = .mixed
        }
        progress(pageCount, pageCount)
        return DocumentProfile(
            pageCount: pageCount,
            sampledPageCount: 0,
            textCharacterCount: 0,
            imageDominantPageCount: 0,
            formFieldCount: formFieldCount,
            byteCount: byteCount,
            isEncrypted: isEncrypted,
            isLocked: isEncrypted,
            allowsCopying: !isEncrypted,
            allowsCommenting: !isEncrypted,
            kind: kind,
            recommendedActions: recommendations(
                kind: kind,
                pageCount: pageCount,
                isLocked: isEncrypted
            )
        )
    }

    private func sparseStructureData(
        descriptor: Int32,
        byteCount: Int64
    ) throws -> Data {
        var result = Data()
        var position: off_t = 0
        var extentCount = 0
        while position < byteCount {
            try Task.checkCancellation()
            errno = 0
            let dataOffset = Darwin.lseek(
                descriptor,
                position,
                SEEK_DATA
            )
            if dataOffset < 0, errno == ENXIO {
                break
            }
            guard dataOffset >= position,
                  dataOffset < byteCount else {
                throw PaperPathError.unreadablePDF
            }
            errno = 0
            let rawHoleOffset = Darwin.lseek(
                descriptor,
                dataOffset,
                SEEK_HOLE
            )
            guard rawHoleOffset > dataOffset else {
                throw PaperPathError.unreadablePDF
            }
            let holeOffset = min(rawHoleOffset, off_t(byteCount))
            let extentByteCount = Int64(holeOffset - dataOffset)
            guard extentByteCount > 0,
                  extentByteCount
                    <= Int64(
                        maximumSparseStructureBytes - result.count
                    ),
                  extentCount < 1_024 else {
                throw PaperPathError.fileTooLarge
            }
            result.append(0x0A)
            try appendBytes(
                from: descriptor,
                offset: dataOffset,
                count: Int(extentByteCount),
                to: &result
            )
            position = holeOffset
            extentCount += 1
        }
        guard !result.isEmpty else {
            throw PaperPathError.unreadablePDF
        }
        return result
    }

    private func appendBytes(
        from descriptor: Int32,
        offset: off_t,
        count: Int,
        to result: inout Data
    ) throws {
        var remaining = count
        var position = offset
        while remaining > 0 {
            try Task.checkCancellation()
            let requestedByteCount = min(remaining, 1_048_576)
            var chunk = Data(count: requestedByteCount)
            var readByteCount: Int
            repeat {
                readByteCount = chunk.withUnsafeMutableBytes { buffer in
                    guard let address = buffer.baseAddress else {
                        return -1
                    }
                    return Darwin.pread(
                        descriptor,
                        address,
                        requestedByteCount,
                        position
                    )
                }
            } while readByteCount < 0 && errno == EINTR
            guard readByteCount == requestedByteCount else {
                throw PaperPathError.unreadablePDF
            }
            result.append(chunk)
            remaining -= readByteCount
            position += off_t(readByteCount)
        }
    }

    private func sparseMetadataText(from text: String) throws -> String {
        guard let streamExpression = try? NSRegularExpression(
            pattern: #"(>>)[ \t]*(?:\r\n|\r|\n)?[ \t]*stream(?:\r\n|\r|\n)[\s\S]*?(?:\r\n|\r|\n)endstream[ \t]*(?=(?:\r\n|\r|\n)[ \t]*endobj\b)"#
        ) else {
            throw PaperPathError.unreadablePDF
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let result = streamExpression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1\n"
        )
        let unresolvedStreamPatterns = [
            #"\bstream(?:\r\n|\r|\n)"#,
            #"\bendstream\b"#
        ]
        guard unresolvedStreamPatterns.allSatisfy({
            result.range(of: $0, options: .regularExpression) == nil
        }) else {
            throw PaperPathError.unreadablePDF
        }
        return result
    }

    func sparseStructuralText(from text: String) throws -> String {
        let bytes = Array(text.utf8)
        var result = [UInt8]()
        result.reserveCapacity(bytes.count)
        var literalDepth = 0
        var literalEscape = false
        var inComment = false

        for byte in bytes {
            if inComment {
                if byte == 0x0A || byte == 0x0D {
                    inComment = false
                    result.append(byte)
                } else {
                    result.append(0x20)
                }
                continue
            }

            if literalDepth > 0 {
                if literalEscape {
                    literalEscape = false
                } else if byte == 0x5C {
                    literalEscape = true
                } else if byte == 0x28 {
                    literalDepth += 1
                } else if byte == 0x29 {
                    literalDepth -= 1
                }
                result.append(
                    byte == 0x0A || byte == 0x0D ? byte : 0x20
                )
                continue
            }

            if byte == 0x25 {
                inComment = true
                result.append(0x20)
            } else if byte == 0x28 {
                literalDepth = 1
                result.append(0x20)
            } else {
                result.append(byte)
            }
        }

        guard literalDepth == 0 else {
            throw PaperPathError.unreadablePDF
        }
        return String(decoding: result, as: UTF8.self)
    }

    private func sparseHeaderIsValid(in text: String) -> Bool {
        String(text.prefix(1_024)).range(
            of: #"%PDF-[0-9]\.[0-9]"#,
            options: .regularExpression
        ) != nil
    }

    private func sparseFooterIsValid(in text: String) -> Bool {
        text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).range(
            of: #"\bstartxref\s+[0-9]+\s+%%EOF$"#,
            options: .regularExpression
        ) != nil
    }

    private func sparseTrailerBodies(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\btrailer\b([\s\S]{0,1048576}?)\bstartxref\b"#
        ) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap {
            guard $0.numberOfRanges == 2,
                  let bodyRange = Range($0.range(at: 1), in: text)
            else {
                return nil
            }
            return String(text[bodyRange])
        }
    }

    private func sparseObjectBody(
        objectNumber: Int,
        generationNumber: Int,
        in text: String
    ) -> String? {
        let pattern =
            #"(?m)^[ \t]*"#
            + String(objectNumber)
            + #"[ \t]+"#
            + String(generationNumber)
            + #"[ \t]+obj\b([\s\S]{0,1048576}?)\bendobj\b"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).reversed()
            .compactMap {
                guard $0.numberOfRanges == 2,
                      let bodyRange = Range(
                        $0.range(at: 1),
                        in: text
                      )
                else {
                    return nil
                }
                return String(text[bodyRange])
            }
            .first
    }

    private func pdfIndirectReference(
        for key: String,
        in text: String
    ) -> (objectNumber: Int, generationNumber: Int)? {
        let pattern =
            NSRegularExpression.escapedPattern(for: "/\(key)")
            + #"\s+([0-9]+)\s+([0-9]+)\s+R\b"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).reversed()
            .compactMap {
                guard $0.numberOfRanges == 3,
                      let objectRange = Range(
                        $0.range(at: 1),
                        in: text
                      ),
                      let generationRange = Range(
                        $0.range(at: 2),
                        in: text
                      ),
                      let objectNumber = Int(text[objectRange]),
                      let generationNumber = Int(
                        text[generationRange]
                      )
                else {
                    return nil
                }
                return (objectNumber, generationNumber)
            }
            .first
    }

    private func pdfInteger(
        for key: String,
        in text: String
    ) -> Int? {
        let pattern =
            NSRegularExpression.escapedPattern(for: "/\(key)")
            + #"\s+([0-9]+)\b"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap {
            guard $0.numberOfRanges == 2,
                  let valueRange = Range($0.range(at: 1), in: text)
            else {
                return nil
            }
            return Int(text[valueRange])
        }.first
    }

    private func containsPDFNamePair(
        key: String,
        value: String,
        in text: String
    ) -> Bool {
        text.range(
            of: NSRegularExpression.escapedPattern(for: "/\(key)")
                + #"\s+"#
                + NSRegularExpression.escapedPattern(for: "/\(value)")
                + #"\b"#,
            options: .regularExpression
        ) != nil
    }

    private func containsPDFToken(
        _ token: String,
        in text: String
    ) -> Bool {
        text.range(
            of: NSRegularExpression.escapedPattern(for: token)
                + #"(?=\s|/|<|>|\[|\]|\(|\))"#,
            options: .regularExpression
        ) != nil
    }

    private func pdfTokenCount(
        pattern: String,
        in text: String
    ) -> Int {
        guard let expression = try? NSRegularExpression(
            pattern: pattern
        ) else {
            return 0
        }
        return expression.numberOfMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
    }

    private func countFormFields(
        in document: CGPDFDocument,
        progress: @Sendable (Int, Int) -> Void
    ) throws -> Int {
        var fieldCount = 0
        let reportingStride = inspectionReportingStride(
            pageCount: document.numberOfPages
        )
        for pageNumber in 1...document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: pageNumber),
                  let dictionary = page.dictionary
            else {
                throw PaperPathError.invalidPage
            }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(
                dictionary,
                "Annots",
                &annotations
            ),
                  let annotations
            else {
                if pageNumber.isMultiple(of: reportingStride)
                    || pageNumber == document.numberOfPages {
                    progress(pageNumber, document.numberOfPages)
                }
                continue
            }
            let annotationCount = CGPDFArrayGetCount(annotations)
            guard annotationCount <= maximumAnnotationsPerPage else {
                throw PaperPathError.insufficientSelection(
                    "A PDF page contains too many annotations to inspect safely."
                )
            }
            for index in 0..<annotationCount {
                if index.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                var annotation: CGPDFDictionaryRef?
                var subtype: UnsafePointer<CChar>?
                guard CGPDFArrayGetDictionary(
                    annotations,
                    index,
                    &annotation
                ),
                      let annotation,
                      CGPDFDictionaryGetName(
                          annotation,
                          "Subtype",
                          &subtype
                      ),
                      let subtype,
                      String(cString: subtype)
                        .caseInsensitiveCompare("Widget")
                        == .orderedSame
                else { continue }
                fieldCount += 1
                guard fieldCount <= maximumFormFieldCount else {
                    throw PaperPathError.insufficientSelection(
                        "This PDF contains too many form fields to inspect safely."
                    )
                }
            }
            if pageNumber.isMultiple(of: reportingStride)
                || pageNumber == document.numberOfPages {
                progress(pageNumber, document.numberOfPages)
            }
        }
        return fieldCount
    }

    private func sampledIndices(pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        guard pageCount > maximumSampledPages else {
            return Array(0..<pageCount)
        }

        return (0..<maximumSampledPages).map { position in
            Int(
                (Double(position) * Double(pageCount - 1))
                    / Double(maximumSampledPages - 1)
            )
        }
    }

    private func inspectionReportingStride(pageCount: Int) -> Int {
        max(1, (pageCount + 199) / 200)
    }

    private func classify(
        sampledPageCount: Int,
        imageDominantPageCount: Int,
        formFieldCount: Int,
        isEncrypted: Bool,
        allowsCopying: Bool,
        allowsCommenting: Bool
    ) -> DocumentKind {
        if isEncrypted || !allowsCopying || !allowsCommenting {
            return .protected
        }
        if formFieldCount > 0 {
            return .form
        }
        guard sampledPageCount > 0 else {
            return .text
        }

        let ratio = Double(imageDominantPageCount) / Double(sampledPageCount)
        if ratio >= 0.8 {
            return .scan
        }
        if ratio >= 0.2 {
            return .mixed
        }
        return .text
    }

    private func recommendations(
        kind: DocumentKind,
        pageCount: Int,
        isLocked: Bool
    ) -> [DocumentAction] {
        guard !isLocked else { return [.inspect, .shareCopy] }

        var result: [DocumentAction] = []
        if kind == .scan || kind == .mixed {
            result.append(.recognizeText)
        }
        if kind == .form {
            result.append(.reviewForm)
        }
        if pageCount > 1 {
            result.append(.organizePages)
        }
        result.append(.inspect)
        result.append(.shareCopy)
        return result
    }
}
