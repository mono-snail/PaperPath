import CoreGraphics
import Foundation
import PDFKit

struct PDFInspectionService {
    private let maximumSampledPages = 12
    private let maximumPageCount = 100_000
    private let maximumAnnotationsPerPage = 4_096
    private let maximumFormFieldCount = 100_000
    private let imageDominantCharacterThreshold = 24

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
        guard byteCount > 0,
              let document = CGPDFDocument(url as CFURL),
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
