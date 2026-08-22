import Foundation
import PDFKit

struct PDFInspectionService {
    private let maximumSampledPages = 12
    private let imageDominantCharacterThreshold = 24

    func inspect(url: URL) throws -> DocumentProfile {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: url) else {
            throw PaperPathError.unreadablePDF
        }

        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0

        if document.isLocked {
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

        let sampleIndices = sampledIndices(pageCount: document.pageCount)
        var textCharacterCount = 0
        var imageDominantPageCount = 0
        var formFieldCount = 0

        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            formFieldCount += autoreleasepool {
                guard let page = document.page(at: index) else {
                    return 0
                }
                return page.annotations.reduce(into: 0) {
                    count, annotation in
                    let normalizedType = annotation.type?
                        .trimmingCharacters(
                            in: CharacterSet(charactersIn: "/")
                        )
                        .lowercased()
                    let widgetType = PDFAnnotationSubtype.widget
                        .rawValue.lowercased()
                    if normalizedType == widgetType
                        || annotation.fieldName != nil {
                        count += 1
                    }
                }
            }
        }

        for index in sampleIndices {
            try Task.checkCancellation()
            let count: Int = autoreleasepool {
                guard let page = document.page(at: index) else {
                    return 0
                }
                return page.string?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .count ?? 0
            }
            textCharacterCount += count
            if count < imageDominantCharacterThreshold {
                imageDominantPageCount += 1
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
