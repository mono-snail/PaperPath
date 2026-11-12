import CryptoKit
import Foundation
import PDFKit

struct PDFEmbeddedAttachmentPayload: Sendable {
    let snapshot: PDFEmbeddedAttachmentSnapshot
    let data: Data?
}

struct PDFStructuralPreservationSignature: Equatable, Sendable {
    let annotationCounts: [Int]
    let attachments: [String]
    let readOnlyReviews: [String]
    let outlineEntries: [String]
    let pageLabels: [String]?
}

struct PDFDocumentStructureService: Sendable {
    private static let maximumPageCount = 100_000
    private static let maximumAnnotationsPerPage = 4_096
    private static let maximumAnnotationsScanned = 100_000
    private static let maximumFormFieldCount = 100_000
    private static let maximumAttachmentCount = 256
    private static let maximumAttachmentBytes = 64 * 1_024 * 1_024
    private static let maximumDecodedBytes = 192 * 1_024 * 1_024
    private static let maximumPreservedAttachmentBytes =
        64 * 1_024 * 1_024
    private static let maximumSourceBytes: Int64 =
        1_024 * 1_024 * 1_024

    static func unfilteredAttachmentCopyIsBounded(
        sourceByteCount: Int
    ) -> Bool {
        sourceByteCount > 0
            && sourceByteCount <= Self.maximumAttachmentBytes
    }

    private func readableSourceByteCount(at url: URL) throws -> Int {
        try Task.checkCancellation()
        let values = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              Int64(byteCount) <= Self.maximumSourceBytes
        else {
            throw PaperPathError.fileTooLarge
        }
        return byteCount
    }

    private func requireTemporaryWriteCapacity(
        at destinationURL: URL,
        byteCount: Int
    ) throws {
        guard byteCount >= 0 else {
            throw PaperPathError.outputVerificationFailed(
                "an extracted attachment has an invalid size"
            )
        }
        let parentURL = destinationURL.deletingLastPathComponent()
        let values = try parentURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available =
                values.volumeAvailableCapacityForImportantUsage
        else { return }
        let required = Int64(byteCount)
            .addingReportingOverflow(16 * 1_024 * 1_024)
        guard !required.overflow,
              available >= required.partialValue
        else {
            throw PaperPathError.insufficientStorage
        }
    }

    func fileSHA256(
        at url: URL,
        expectedByteCount: Int
    ) throws -> String {
        guard expectedByteCount >= 0 else {
            throw PaperPathError.outputVerificationFailed(
                "an extracted attachment has an invalid size"
            )
        }
        let values = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == expectedByteCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the extracted attachment size changed after writing"
            )
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var totalByteCount = 0
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1_048_576)
                ?? Data()
            guard !chunk.isEmpty else { break }
            let (nextTotal, overflow) = totalByteCount
                .addingReportingOverflow(chunk.count)
            guard !overflow, nextTotal <= expectedByteCount else {
                throw PaperPathError.outputVerificationFailed(
                    "the extracted attachment exceeded its expected size"
                )
            }
            totalByteCount = nextTotal
            hasher.update(data: chunk)
        }
        guard totalByteCount == expectedByteCount else {
            throw PaperPathError.outputVerificationFailed(
                "the extracted attachment ended before its expected size"
            )
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func attachments(
        in url: URL,
        unlockPassword: String? = nil
    ) throws -> [PDFEmbeddedAttachmentSnapshot] {
        try decodedAttachmentPayloads(
            in: url,
            unlockPassword: unlockPassword,
            retainingDataFor: []
        ).map(\.snapshot)
    }

    func attachmentPayloads(
        in url: URL,
        unlockPassword: String? = nil
    ) throws -> [PDFEmbeddedAttachmentPayload] {
        try decodedAttachmentPayloads(
            in: url,
            unlockPassword: unlockPassword,
            maximumDecodedBytes:
                Self.maximumPreservedAttachmentBytes
        )
    }

    func extractAttachments(
        in sourceURL: URL,
        matching attachmentIDs: Set<String>,
        to directory: URL
    ) throws -> [URL] {
        guard !attachmentIDs.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Select at least one embedded file to extract."
            )
        }
        let selected = try decodedAttachmentPayloads(
            in: sourceURL,
            retainingDataFor: attachmentIDs
        ).filter {
            attachmentIDs.contains($0.snapshot.id)
        }
        guard selected.count == attachmentIDs.count else {
            throw PaperPathError.outputVerificationFailed(
                "one or more embedded files changed before extraction"
            )
        }
        guard selected.allSatisfy({
            $0.snapshot.isExtractable && $0.data != nil
        }) else {
            throw PaperPathError.insufficientSelection(
                "One or more embedded files exceed the safe local extraction limit."
            )
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let directoryValues = try directory.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true
        else {
            throw PaperPathError.storageFailure(
                "The attachment export folder is invalid."
            )
        }
        try LocalFileSecurity.requireCompleteProtection(
            to: directory,
            fileManager: fileManager
        )
        LocalFileSecurity.excludeFromBackup(directory)

        var usedNames: Set<String> = []
        var outputURLs: [URL] = []
        do {
            for payload in selected {
                try Task.checkCancellation()
                guard let data = payload.data else {
                    throw PaperPathError.outputVerificationFailed(
                        "an embedded file payload is unavailable"
                    )
                }
                let fileName = uniqueFileName(
                    payload.snapshot.fileName,
                    usedNames: &usedNames
                )
                let destination = directory
                    .appendingPathComponent(fileName, isDirectory: false)
                try requireTemporaryWriteCapacity(
                    at: destination,
                    byteCount: data.count
                )
                try data.write(to: destination, options: .atomic)
                try LocalFileSecurity.requireCompleteProtection(
                    to: destination,
                    fileManager: fileManager
                )
                let writtenDigest = try fileSHA256(
                    at: destination,
                    expectedByteCount: payload.snapshot.byteCount
                )
                guard writtenDigest == payload.snapshot.checksum else {
                    throw PaperPathError.outputVerificationFailed(
                        "the extracted file bytes did not match the PDF attachment"
                    )
                }
                outputURLs.append(destination)
            }
            return outputURLs
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func pageLabels(
        in url: URL,
        unlockPassword: String? = nil
    ) throws -> [PDFPageLabelSnapshot] {
        let document = try unlockedPDFDocument(
            at: url,
            password: unlockPassword
        )
        guard document.pageCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        let cgDocument = try unlockedCGPDFDocument(
            at: url,
            password: unlockPassword
        )
        var pageLabelsObject: CGPDFObjectRef?
        let hasExplicitLabels = cgDocument.catalog.map {
            CGPDFDictionaryGetObject(
                $0,
                "PageLabels",
                &pageLabelsObject
            )
        } == true
        return try (0..<document.pageCount).map { index in
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw PaperPathError.invalidPage
            }
            let value = page.label?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PDFPageLabelSnapshot(
                pageIndex: index,
                label: value.flatMap {
                    $0.isEmpty ? nil : $0
                } ?? String(index + 1),
                isExplicit: hasExplicitLabels
            )
        }
    }

    func unsupportedReviewAnnotations(
        in url: URL,
        unlockPassword: String? = nil,
        resultLimit: Int? = nil
    ) throws -> [PDFAnnotationSnapshot] {
        let document = try unlockedCGPDFDocument(
            at: url,
            password: unlockPassword
        )
        let supportedReadOnlyTypes = Set([
            "polygon",
            "polyline",
            "squiggly",
            "caret"
        ])
        let maximumResults = resultLimit.map {
            max(1, min($0, 10_001))
        }
        var results: [PDFAnnotationSnapshot] = []
        var scannedAnnotationCount = 0
        for pageIndex in 0..<document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex + 1),
                  let pageDictionary = page.dictionary
            else { throw PaperPathError.invalidPage }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(
                pageDictionary,
                "Annots",
                &annotations
            ),
                  let annotations
            else { continue }
            let count = CGPDFArrayGetCount(annotations)
            guard count <= Self.maximumAnnotationsPerPage else {
                throw PaperPathError.insufficientSelection(
                    "A PDF page contains too many annotations to inspect safely."
                )
            }
            let nextScannedCount = scannedAnnotationCount
                .addingReportingOverflow(count)
            guard !nextScannedCount.overflow,
                  nextScannedCount.partialValue
                    <= Self.maximumAnnotationsScanned
            else {
                throw PaperPathError.insufficientSelection(
                    "This PDF contains too many annotations to inspect safely."
                )
            }
            scannedAnnotationCount = nextScannedCount.partialValue
            for rawIndex in 0..<count {
                if rawIndex.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                if let maximumResults,
                   results.count >= maximumResults {
                    return results
                }
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(
                    annotations,
                    rawIndex,
                    &dictionary
                ),
                      let dictionary,
                      let subtype = pdfName(
                          in: dictionary,
                          key: "Subtype"
                      ),
                      supportedReadOnlyTypes.contains(
                          subtype.lowercased()
                      )
                else { continue }
                var appearance: CGPDFObjectRef?
                let hasAppearance = CGPDFDictionaryGetObject(
                    dictionary,
                    "AP",
                    &appearance
                )
                let color = annotationColor(in: dictionary)
                results.append(
                    PDFAnnotationSnapshot(
                        pageIndex: pageIndex,
                        annotationIndex: -(rawIndex + 1),
                        type: subtype,
                        contents: pdfString(
                            in: dictionary,
                            key: "Contents"
                        ),
                        generatedKind:
                            PDFGeneratedAnnotationKind.resolve(
                                author: pdfString(
                                    in: dictionary,
                                    key: "T"
                                )
                            ),
                        color: color,
                        lineWidth: annotationLineWidth(
                            in: dictionary
                        ),
                        hasAppearanceStream: hasAppearance,
                        canEditContents: false,
                        canEditStyle: false,
                        canRemove: false
                    )
                )
            }
        }
        return results
    }

    func preservationSignature(
        in url: URL,
        unlockPassword: String? = nil,
        includePageLabels: Bool = false
    ) throws -> PDFStructuralPreservationSignature {
        let document = try unlockedPDFDocument(
            at: url,
            password: unlockPassword
        )
        var annotationCounts: [Int] = []
        annotationCounts.reserveCapacity(document.pageCount)
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            let annotationCount = page.annotations.count
            guard annotationCount <= Self.maximumAnnotationsPerPage else {
                throw PaperPathError.insufficientSelection(
                    "A PDF page contains too many annotations to inspect safely."
                )
            }
            annotationCounts.append(annotationCount)
        }
        let attachments = try attachments(
            in: url,
            unlockPassword: unlockPassword
        ).map {
            [
                $0.origin.rawValue,
                $0.pageIndex.map(String.init) ?? "document",
                $0.fileName,
                String($0.byteCount),
                $0.checksum,
                $0.contentType ?? ""
            ].joined(separator: "|")
        }.sorted()
        let reviews = try unsupportedReviewAnnotations(
            in: url,
            unlockPassword: unlockPassword
        ).map {
            [
                String($0.pageIndex),
                $0.type,
                $0.contents ?? ""
            ].joined(separator: "|")
        }.sorted()
        var outlineEntries: [String] = []
        if let root = document.outlineRoot {
            func walk(_ item: PDFOutline, depth: Int) throws {
                guard depth < 24,
                      outlineEntries.count < 2_000
                else { return }
                for index in 0..<item.numberOfChildren {
                    if index.isMultiple(of: 64) {
                        try Task.checkCancellation()
                    }
                    guard outlineEntries.count < 2_000 else {
                        break
                    }
                    guard let child = item.child(at: index) else {
                        continue
                    }
                    let pageIndex = child.destination?.page.map {
                        document.index(for: $0)
                    } ?? NSNotFound
                    outlineEntries.append(
                        "\(depth)|\(child.label ?? "")|\(pageIndex)"
                    )
                    try walk(child, depth: depth + 1)
                }
            }
            try walk(root, depth: 0)
        }
        let labels = includePageLabels
            ? try pageLabels(
                in: url,
                unlockPassword: unlockPassword
            ).map {
                "\($0.pageIndex)|\($0.label)|\($0.isExplicit)"
            }
            : nil
        return PDFStructuralPreservationSignature(
            annotationCounts: annotationCounts,
            attachments: attachments,
            readOnlyReviews: reviews,
            outlineEntries: outlineEntries,
            pageLabels: labels
        )
    }

    func technicalInspection(
        in url: URL,
        profile: DocumentProfile,
        source: PDFSourceLocationSnapshot?,
        unlockPassword: String? = nil
    ) throws -> PDFTechnicalInspection {
        guard let document = PDFDocument(url: url) else {
            throw PaperPathError.unreadablePDF
        }
        if document.isLocked,
           let unlockPassword,
           !unlockPassword.isEmpty {
            _ = document.unlock(withPassword: unlockPassword)
        }
        try Self.requireSupportedPageCount(document.pageCount)

        let byteCount = (try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize).map(Int64.init) ?? profile.byteCount
        let coverage = profile.sampledPageCount > 0
            ? profile.textCoverage
            : nil

        guard !document.isLocked else {
            return PDFTechnicalInspection(
                byteCount: byteCount,
                pageCount: document.pageCount,
                sampledPageCount: profile.sampledPageCount,
                textCoverage: coverage,
                imageDominantPageCount: nil,
                formFieldCount: nil,
                annotationCount: nil,
                attachmentCount: nil,
                outlineEntryCount: nil,
                hasExplicitPageLabels: nil,
                isEncrypted: document.isEncrypted,
                isLocked: true,
                permissions: nil,
                source: source
            )
        }

        let signature = try preservationSignature(
            in: url,
            unlockPassword: unlockPassword,
            includePageLabels: true
        )
        let rawPermissions = document.accessPermissions.rawValue
        func allows(_ permission: PDFAccessPermissions) -> Bool {
            rawPermissions & permission.rawValue == permission.rawValue
        }
        var formFieldCount = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw PaperPathError.invalidPage
            }
            for (annotationIndex, annotation) in
                page.annotations.enumerated() {
                if annotationIndex.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                let type = annotation.type?
                    .trimmingCharacters(
                        in: CharacterSet(charactersIn: "/")
                    )
                    .lowercased()
                let widgetType = PDFAnnotationSubtype.widget.rawValue
                    .trimmingCharacters(
                        in: CharacterSet(charactersIn: "/")
                    )
                    .lowercased()
                if type == widgetType
                    || annotation.fieldName != nil {
                    guard formFieldCount
                        < Self.maximumFormFieldCount
                    else {
                        throw PaperPathError.insufficientSelection(
                            "This PDF contains too many form fields to inspect safely."
                        )
                    }
                    formFieldCount += 1
                }
            }
        }
        let hasExplicitPageLabels = signature.pageLabels?
            .contains { $0.hasSuffix("|true") } ?? false
        let annotationCount = signature.annotationCounts.reduce(0) {
            count, pageCount in
            let (next, overflow) = count.addingReportingOverflow(
                max(0, pageCount)
            )
            return overflow ? .max : next
        }

        return PDFTechnicalInspection(
            byteCount: byteCount,
            pageCount: document.pageCount,
            sampledPageCount: profile.sampledPageCount,
            textCoverage: coverage,
            imageDominantPageCount:
                profile.sampledPageCount > 0
                    ? profile.imageDominantPageCount
                    : nil,
            formFieldCount: formFieldCount,
            annotationCount: annotationCount,
            attachmentCount: signature.attachments.count,
            outlineEntryCount: signature.outlineEntries.count,
            hasExplicitPageLabels: hasExplicitPageLabels,
            isEncrypted: document.isEncrypted,
            isLocked: false,
            permissions: PDFTechnicalPermissions(
                allowsHighQualityPrinting: allows(
                    .allowsHighQualityPrinting
                ),
                allowsCopying: allows(.allowsContentCopying),
                allowsCommenting: allows(.allowsCommenting),
                allowsFormFilling: allows(.allowsFormFieldEntry),
                allowsDocumentAssembly: allows(
                    .allowsDocumentAssembly
                ),
                allowsContentAccessibility: allows(
                    .allowsContentAccessibility
                )
            ),
            source: source
        )
    }

    func decodedAttachmentPayloads(
        in url: URL,
        unlockPassword: String? = nil,
        retainingDataFor retainedAttachmentIDs: Set<String>? = nil,
        maximumDecodedBytes: Int = Self.maximumDecodedBytes
    ) throws -> [PDFEmbeddedAttachmentPayload] {
        let sourceByteCount = try readableSourceByteCount(at: url)
        guard maximumDecodedBytes > 0,
              maximumDecodedBytes <= Self.maximumDecodedBytes
        else {
            throw PaperPathError.insufficientSelection(
                "The attachment memory budget is invalid."
            )
        }
        let stableSourceData: Data?
        if Self.unfilteredAttachmentCopyIsBounded(
            sourceByteCount: sourceByteCount
        ) {
            let data = try Data(
                contentsOf: url,
                options: .alwaysMapped
            )
            guard data.count == sourceByteCount,
                  Self.unfilteredAttachmentCopyIsBounded(
                    sourceByteCount: data.count
                  )
            else {
                throw PaperPathError.fileTooLarge
            }
            stableSourceData = data
        } else {
            stableSourceData = nil
        }

        let document: CGPDFDocument
        if let stableSourceData {
            _ = try unlockedPDFDocument(
                data: stableSourceData,
                password: unlockPassword
            )
            document = try unlockedCGPDFDocument(
                data: stableSourceData,
                password: unlockPassword
            )
        } else {
            _ = try unlockedPDFDocument(
                at: url,
                password: unlockPassword
            )
            document = try unlockedCGPDFDocument(
                at: url,
                password: unlockPassword
            )
        }
        guard let catalog = document.catalog else {
            throw PaperPathError.unreadablePDF
        }

        var results: [PDFEmbeddedAttachmentPayload] = []
        var decodedByteCount = 0
        let encodedAttachments = stableSourceData.map(boundedEncodedAttachments) ?? [:]

        func append(
            fileSpec: CGPDFDictionaryRef,
            fallbackName: String?,
            description: String?,
            pageIndex: Int?,
            origin: PDFEmbeddedAttachmentOrigin
        ) {
            guard !Task.isCancelled,
                  results.count < Self.maximumAttachmentCount,
                  let payload = attachmentPayload(
                      fileSpec: fileSpec,
                      fallbackName: fallbackName,
                      fallbackDescription: description,
                      pageIndex: pageIndex,
                      origin: origin,
                      decodedByteCount: decodedByteCount,
                      maximumDecodedBytes: maximumDecodedBytes,
                      sourceByteCount: sourceByteCount,
                      encodedAttachments: encodedAttachments
                  )
            else { return }
            let duplicate = results.contains {
                $0.snapshot.checksum.isEmpty == false
                    && $0.snapshot.checksum
                        == payload.snapshot.checksum
                    && $0.snapshot.fileName
                        .caseInsensitiveCompare(
                            payload.snapshot.fileName
                        ) == .orderedSame
                    && (
                        $0.snapshot.pageIndex
                            == payload.snapshot.pageIndex
                        || (
                            $0.snapshot.origin == .pageAnnotation
                                && payload.snapshot.origin == .document
                        )
                    )
            }
            if !duplicate {
                if let data = payload.data {
                    decodedByteCount += data.count
                }
                let keepsData = retainedAttachmentIDs.map {
                    $0.contains(payload.snapshot.id)
                } ?? true
                results.append(
                    PDFEmbeddedAttachmentPayload(
                        snapshot: payload.snapshot,
                        data: keepsData ? payload.data : nil
                    )
                )
            }
        }

        for pageIndex in 0..<document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex + 1),
                  let pageDictionary = page.dictionary
            else { throw PaperPathError.invalidPage }

            if let associatedFiles = pdfArray(
                in: pageDictionary,
                key: "AF"
            ) {
                appendFileSpecs(
                    in: associatedFiles,
                    pageIndex: pageIndex,
                    origin: .pageAnnotation,
                    append: append
                )
            }

            guard let annotations = pdfArray(
                in: pageDictionary,
                key: "Annots"
            ) else { continue }
            let count = CGPDFArrayGetCount(annotations)
            guard count <= Self.maximumAnnotationsPerPage else {
                throw PaperPathError.insufficientSelection(
                    "A PDF page contains too many annotations to inspect safely."
                )
            }
            for annotationIndex in 0..<count {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(
                    annotations,
                    annotationIndex,
                    &annotation
                ),
                      let annotation,
                      pdfName(
                          in: annotation,
                          key: "Subtype"
                      )?.caseInsensitiveCompare("FileAttachment")
                        == .orderedSame,
                      let fileSpec = pdfDictionary(
                          in: annotation,
                          key: "FS"
                      )
                else { continue }
                append(
                    fileSpec: fileSpec,
                    fallbackName: nil,
                    description: pdfString(
                        in: annotation,
                        key: "Contents"
                    ),
                    pageIndex: pageIndex,
                    origin: .pageAnnotation
                )
            }
        }

        if let associatedFiles = pdfArray(in: catalog, key: "AF") {
            appendFileSpecs(
                in: associatedFiles,
                pageIndex: nil,
                origin: .document,
                append: append
            )
        }

        if let names = pdfDictionary(in: catalog, key: "Names"),
           let embeddedFiles = pdfDictionary(
               in: names,
               key: "EmbeddedFiles"
           ) {
            var remainingNodeBudget = 1_024
            walkNameTree(
                embeddedFiles,
                depth: 0,
                remainingNodeBudget: &remainingNodeBudget
            ) { entryName, fileSpec in
                append(
                    fileSpec: fileSpec,
                    fallbackName: entryName,
                    description: nil,
                    pageIndex: nil,
                    origin: .document
                )
            }
        }

        try Task.checkCancellation()
        return results.sorted {
            switch ($0.snapshot.pageIndex, $1.snapshot.pageIndex) {
            case let (.some(left), .some(right)):
                if left != right { return left < right }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return $0.snapshot.fileName
                .localizedStandardCompare($1.snapshot.fileName)
                == .orderedAscending
        }
    }

    private func unlockedPDFDocument(
        at url: URL,
        password: String?
    ) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw PaperPathError.unreadablePDF
        }
        if document.isLocked {
            guard let password,
                  !password.isEmpty,
                  document.unlock(withPassword: password)
            else {
                throw PaperPathError.lockedPDF
            }
        }
        try Self.requireSupportedPageCount(document.pageCount)
        return document
    }

    private func unlockedPDFDocument(
        data: Data,
        password: String?
    ) throws -> PDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw PaperPathError.unreadablePDF
        }
        if document.isLocked {
            guard let password,
                  !password.isEmpty,
                  document.unlock(withPassword: password)
            else {
                throw PaperPathError.lockedPDF
            }
        }
        try Self.requireSupportedPageCount(document.pageCount)
        return document
    }

    private func unlockedCGPDFDocument(
        at url: URL,
        password: String?
    ) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw PaperPathError.unreadablePDF
        }
        if document.isEncrypted && !document.isUnlocked {
            guard let password,
                  !password.isEmpty,
                  password.withCString({
                      document.unlockWithPassword($0)
                  })
            else {
                throw PaperPathError.lockedPDF
            }
        }
        try Self.requireSupportedPageCount(document.numberOfPages)
        return document
    }

    private func unlockedCGPDFDocument(
        data: Data,
        password: String?
    ) throws -> CGPDFDocument {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else {
            throw PaperPathError.unreadablePDF
        }
        if document.isEncrypted && !document.isUnlocked {
            guard let password,
                  !password.isEmpty,
                  password.withCString({
                      document.unlockWithPassword($0)
                  })
            else {
                throw PaperPathError.lockedPDF
            }
        }
        try Self.requireSupportedPageCount(document.numberOfPages)
        return document
    }

    private static func requireSupportedPageCount(
        _ pageCount: Int
    ) throws {
        guard pageCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        guard pageCount <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Inspect PDFs with up to 100,000 pages."
            )
        }
    }

    private func appendFileSpecs(
        in array: CGPDFArrayRef,
        pageIndex: Int?,
        origin: PDFEmbeddedAttachmentOrigin,
        append: (
            CGPDFDictionaryRef,
            String?,
            String?,
            Int?,
            PDFEmbeddedAttachmentOrigin
        ) -> Void
    ) {
        let count = min(CGPDFArrayGetCount(array), 4_096)
        for index in 0..<count {
            guard !Task.isCancelled else { return }
            var fileSpec: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(
                array,
                index,
                &fileSpec
            ),
                  let fileSpec
            else { continue }
            append(
                fileSpec,
                nil,
                nil,
                pageIndex,
                origin
            )
        }
    }

    private func walkNameTree(
        _ node: CGPDFDictionaryRef,
        depth: Int,
        remainingNodeBudget: inout Int,
        visit: (String?, CGPDFDictionaryRef) -> Void
    ) {
        guard !Task.isCancelled,
              depth < 16,
              remainingNodeBudget > 0
        else { return }
        remainingNodeBudget -= 1

        if let names = pdfArray(in: node, key: "Names") {
            let count = min(CGPDFArrayGetCount(names), 8_192)
            var index = 0
            while index + 1 < count {
                guard !Task.isCancelled else { return }
                var nameValue: CGPDFStringRef?
                var fileSpec: CGPDFDictionaryRef?
                let hasName = CGPDFArrayGetString(
                    names,
                    index,
                    &nameValue
                )
                let hasFileSpec = CGPDFArrayGetDictionary(
                    names,
                    index + 1,
                    &fileSpec
                )
                if hasFileSpec, let fileSpec {
                    visit(
                        hasName
                            ? pdfText(from: nameValue)
                            : nil,
                        fileSpec
                    )
                }
                index += 2
            }
        }

        guard let kids = pdfArray(in: node, key: "Kids") else {
            return
        }
        let count = min(CGPDFArrayGetCount(kids), 1_024)
        for index in 0..<count {
            guard remainingNodeBudget > 0 else { return }
            var child: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(kids, index, &child),
                  let child
            else { continue }
            walkNameTree(
                child,
                depth: depth + 1,
                remainingNodeBudget: &remainingNodeBudget,
                visit: visit
            )
        }
    }

    private func attachmentPayload(
        fileSpec: CGPDFDictionaryRef,
        fallbackName: String?,
        fallbackDescription: String?,
        pageIndex: Int?,
        origin: PDFEmbeddedAttachmentOrigin,
        decodedByteCount: Int,
        maximumDecodedBytes: Int,
        sourceByteCount: Int,
        encodedAttachments: [String: Data]
    ) -> PDFEmbeddedAttachmentPayload? {
        guard let embeddedFiles = pdfDictionary(
            in: fileSpec,
            key: "EF"
        ) else { return nil }
        var stream: CGPDFStreamRef?
        if !CGPDFDictionaryGetStream(
            embeddedFiles,
            "UF",
            &stream
        ) {
            _ = CGPDFDictionaryGetStream(
                embeddedFiles,
                "F",
                &stream
            )
        }
        guard let stream else { return nil }

        let streamDictionary = CGPDFStreamGetDictionary(stream)
        let declaredSize = streamDictionary.flatMap {
            pdfDictionary(in: $0, key: "Params")
        }.flatMap {
            pdfInteger(in: $0, key: "Size")
        }
        let encodedSize = streamDictionary.flatMap {
            pdfInteger(in: $0, key: "Length")
        }
        var filterObject: CGPDFObjectRef?
        let hasFilter = streamDictionary.map {
            CGPDFDictionaryGetObject(
                $0,
                "Filter",
                &filterObject
            )
        } ?? false
        let fileName = normalizedAttachmentName(
            pdfString(in: fileSpec, key: "UF")
                ?? pdfString(in: fileSpec, key: "F")
                ?? fallbackName
                ?? "Attachment"
        )
        let description = pdfString(in: fileSpec, key: "Desc")
            ?? fallbackDescription
        let contentType = streamDictionary.flatMap {
            pdfName(in: $0, key: "Subtype")
        }.map(decodePDFName)

        let boundedDecoded: Data?
        if hasFilter, let declaredSize, declaredSize > 0,
           declaredSize <= Self.maximumAttachmentBytes,
           declaredSize <= maximumDecodedBytes - decodedByteCount,
           let encodedSize, let encoded = encodedAttachments["\(encodedSize):\(declaredSize)"],
           let decoded = pdfInflateZlib(encoded, maximumOutputByteCount: declaredSize), decoded.count == declaredSize {
            boundedDecoded = decoded
        } else { boundedDecoded = nil }
        if hasFilter && boundedDecoded == nil {
            let limitation = declaredSize == nil
                ? "Compressed attachment is missing a trusted decoded size"
                : "Compressed attachments cannot be decoded within the local safety limit"
            let snapshot = attachmentSnapshot(
                fileName: fileName,
                contentType: contentType,
                byteCount: max(0, declaredSize ?? encodedSize ?? 0),
                checksum: "",
                description: description,
                pageIndex: pageIndex,
                origin: origin,
                isExtractable: false,
                limitation: limitation
            )
            return PDFEmbeddedAttachmentPayload(
                snapshot: snapshot,
                data: nil
            )
        }

        let trustedDecodedSize: Int?
        if let declaredSize, declaredSize >= 0 {
            trustedDecodedSize = declaredSize
        } else if let encodedSize,
                  encodedSize >= 0 {
            trustedDecodedSize = encodedSize
        } else {
            trustedDecodedSize = nil
        }
        guard let trustedDecodedSize else {
            let snapshot = attachmentSnapshot(
                fileName: fileName,
                contentType: contentType,
                byteCount: max(0, encodedSize ?? 0),
                checksum: "",
                description: description,
                pageIndex: pageIndex,
                origin: origin,
                isExtractable: false,
                limitation:
                    "Compressed attachment is missing a trusted decoded size"
            )
            return PDFEmbeddedAttachmentPayload(
                snapshot: snapshot,
                data: nil
            )
        }

        let remainingBudget = max(
            0,
            maximumDecodedBytes - decodedByteCount
        )
        guard let encodedSize, encodedSize >= 0 else {
            let snapshot = attachmentSnapshot(
                fileName: fileName,
                contentType: contentType,
                byteCount: trustedDecodedSize,
                checksum: "",
                description: description,
                pageIndex: pageIndex,
                origin: origin,
                isExtractable: false,
                limitation: "Attachment stream size is unavailable"
            )
            return PDFEmbeddedAttachmentPayload(
                snapshot: snapshot,
                data: nil
            )
        }
        guard Self.unfilteredAttachmentCopyIsBounded(
            sourceByteCount: sourceByteCount
        ) else {
            let snapshot = attachmentSnapshot(
                fileName: fileName,
                contentType: contentType,
                byteCount: trustedDecodedSize,
                checksum: "",
                description: description,
                pageIndex: pageIndex,
                origin: origin,
                isExtractable: false,
                limitation:
                    "Source PDF is larger than the 64 MB safe attachment extraction limit"
            )
            return PDFEmbeddedAttachmentPayload(
                snapshot: snapshot,
                data: nil
            )
        }
        if trustedDecodedSize > Self.maximumAttachmentBytes
            || encodedSize > Self.maximumAttachmentBytes
            || trustedDecodedSize > remainingBudget
            || encodedSize > remainingBudget {
            let limitation =
                trustedDecodedSize > Self.maximumAttachmentBytes
                    || encodedSize > Self.maximumAttachmentBytes
                ? "Larger than the 64 MB local extraction limit"
                : "Exceeds the local attachment memory budget"
            let snapshot = attachmentSnapshot(
                fileName: fileName,
                contentType: contentType,
                byteCount: trustedDecodedSize,
                checksum: "",
                description: description,
                pageIndex: pageIndex,
                origin: origin,
                isExtractable: false,
                limitation: limitation
            )
            return PDFEmbeddedAttachmentPayload(
                snapshot: snapshot,
                data: nil
            )
        }

        let data: Data
        if let boundedDecoded { data = boundedDecoded }
        else {
            var format = CGPDFDataFormat.raw
            guard let copied = CGPDFStreamCopyData(stream, &format) else { return nil }
            data = copied as Data
        }
        guard data.count == trustedDecodedSize else {
            let snapshot = attachmentSnapshot(
                fileName: fileName,
                contentType: contentType,
                byteCount: data.count,
                checksum: "",
                description: description,
                pageIndex: pageIndex,
                origin: origin,
                isExtractable: false,
                limitation:
                    "Decoded attachment size does not match its PDF declaration"
            )
            return PDFEmbeddedAttachmentPayload(
                snapshot: snapshot,
                data: nil
            )
        }
        let fitsPerFile = data.count <= Self.maximumAttachmentBytes
        let fitsTotal = decodedByteCount <= maximumDecodedBytes
            - min(data.count, maximumDecodedBytes)
        guard fitsPerFile, fitsTotal else {
            let reason = fitsPerFile
                ? "Exceeds the local attachment memory budget"
                : "Larger than the 64 MB local extraction limit"
            let snapshot = attachmentSnapshot(
                fileName: fileName,
                contentType: contentType,
                byteCount: data.count,
                checksum: "",
                description: description,
                pageIndex: pageIndex,
                origin: origin,
                isExtractable: false,
                limitation: reason
            )
            return PDFEmbeddedAttachmentPayload(
                snapshot: snapshot,
                data: nil
            )
        }
        let checksum = Self.digest(data)
        let snapshot = attachmentSnapshot(
            fileName: fileName,
            contentType: contentType,
            byteCount: data.count,
            checksum: checksum,
            description: description,
            pageIndex: pageIndex,
            origin: origin,
            isExtractable: true,
            limitation: nil
        )
        return PDFEmbeddedAttachmentPayload(
            snapshot: snapshot,
            data: data
        )
    }

    private func attachmentSnapshot(
        fileName: String,
        contentType: String?,
        byteCount: Int,
        checksum: String,
        description: String?,
        pageIndex: Int?,
        origin: PDFEmbeddedAttachmentOrigin,
        isExtractable: Bool,
        limitation: String?
    ) -> PDFEmbeddedAttachmentSnapshot {
        let identity = [
            origin.rawValue,
            pageIndex.map(String.init) ?? "document",
            fileName.lowercased(),
            checksum,
            String(byteCount)
        ].joined(separator: "|")
        let id = Self.digest(Data(identity.utf8))
        return PDFEmbeddedAttachmentSnapshot(
            id: id,
            fileName: fileName,
            contentType: contentType,
            byteCount: byteCount,
            checksum: checksum,
            description: description,
            pageIndex: pageIndex,
            origin: origin,
            isExtractable: isExtractable,
            limitation: limitation
        )
    }

    private func normalizedAttachmentName(_ value: String) -> String {
        let lastComponent = URL(fileURLWithPath: value)
            .lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " .-_()")
        )
        let filtered = lastComponent.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        let normalized = String(filtered)
            .replacingOccurrences(
                of: "-{2,}",
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: ".")
                )
            )
        return String(
            (normalized.isEmpty ? "Attachment" : normalized)
                .prefix(120)
        )
    }

    func uniqueFileName(
        _ value: String,
        usedNames: inout Set<String>
    ) -> String {
        let url = URL(fileURLWithPath: value)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var candidate = value
        var counter = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty
                ? "\(stem) \(counter)"
                : "\(stem) \(counter).\(ext)"
            counter += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }

    func annotationColor(
        in dictionary: CGPDFDictionaryRef
    ) -> PDFInkColor {
        guard let values = pdfArray(in: dictionary, key: "C") else {
            return PDFInkColor(
                red: 0.95,
                green: 0.72,
                blue: 0.08,
                alpha: 1
            )
        }
        let count = CGPDFArrayGetCount(values)
        var components: [Double] = []
        for index in 0..<min(count, 4) {
            var value: CGPDFReal = 0
            if CGPDFArrayGetNumber(values, index, &value) {
                components.append(Double(value))
            }
        }
        switch components.count {
        case 1:
            return PDFInkColor(
                red: components[0],
                green: components[0],
                blue: components[0],
                alpha: 1
            )
        case 3...:
            return PDFInkColor(
                red: components[0],
                green: components[1],
                blue: components[2],
                alpha: 1
            )
        default:
            return PDFInkColor(
                red: 0.95,
                green: 0.72,
                blue: 0.08,
                alpha: 1
            )
        }
    }

    private func annotationLineWidth(
        in dictionary: CGPDFDictionaryRef
    ) -> Double? {
        guard let borderStyle = pdfDictionary(
            in: dictionary,
            key: "BS"
        ),
              let width = pdfNumber(in: borderStyle, key: "W")
        else { return nil }
        return width
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private func pdfDictionary(
    in dictionary: CGPDFDictionaryRef,
    key: String
) -> CGPDFDictionaryRef? {
    var value: CGPDFDictionaryRef?
    return CGPDFDictionaryGetDictionary(
        dictionary,
        key,
        &value
    ) ? value : nil
}

private func pdfArray(
    in dictionary: CGPDFDictionaryRef,
    key: String
) -> CGPDFArrayRef? {
    var value: CGPDFArrayRef?
    return CGPDFDictionaryGetArray(
        dictionary,
        key,
        &value
    ) ? value : nil
}

private func pdfString(
    in dictionary: CGPDFDictionaryRef,
    key: String
) -> String? {
    var value: CGPDFStringRef?
    guard CGPDFDictionaryGetString(
        dictionary,
        key,
        &value
    ) else { return nil }
    return pdfText(from: value)
}

private func pdfText(
    from value: CGPDFStringRef?
) -> String? {
    guard let value,
          let text = CGPDFStringCopyTextString(value)
    else { return nil }
    return text as String
}

private func pdfName(
    in dictionary: CGPDFDictionaryRef,
    key: String
) -> String? {
    var value: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(
        dictionary,
        key,
        &value
    ),
          let value
    else { return nil }
    return String(cString: value)
}

private func pdfInteger(
    in dictionary: CGPDFDictionaryRef,
    key: String
) -> Int? {
    var value: CGPDFInteger = 0
    guard CGPDFDictionaryGetInteger(
        dictionary,
        key,
        &value
    ) else { return nil }
    return Int(value)
}

private func pdfNumber(
    in dictionary: CGPDFDictionaryRef,
    key: String
) -> Double? {
    var value: CGPDFReal = 0
    guard CGPDFDictionaryGetNumber(
        dictionary,
        key,
        &value
    ) else { return nil }
    return Double(value)
}

func decodePDFName(_ value: String) -> String {
    var result = ""
    var index = value.startIndex
    while index < value.endIndex {
        if value[index] == "#" {
            let first = value.index(after: index)
            if first < value.endIndex {
                let second = value.index(after: first)
                if second < value.endIndex {
                    let end = value.index(after: second)
                    if let byte = UInt8(value[first..<end], radix: 16) {
                        result.append(Character(UnicodeScalar(byte)))
                        index = end
                        continue
                    }
                }
            }
        }
        result.append(value[index])
        index = value.index(after: index)
    }
    return result
}

private extension PDFDocumentStructureService {
    /// Extract encoded bytes directly, then use the bounded zlib decoder.
    /// A claimed /Size never authorizes unbounded CGPDFStreamCopyData inflation.
    func boundedEncodedAttachments(_ data: Data) -> [String: Data] {
        guard data.count <= 64 * 1_024 * 1_024,
              let structure = try? PDFImageObjectDocument(data: data, allowZeroOffsetPlaceholders: true) else { return [:] }
        var candidates: [String: [Data]] = [:]
        let references = structure.allObjects()
        for (index, reference) in references.enumerated() {
            if Task.isCancelled { return [:] }
            let end = index + 1 < references.count ? references[index + 1].offset : data.count
            guard reference.offset < end, end - reference.offset <= 32 * 1_024 * 1_024 else { continue }
            let prefix = Data(data[reference.offset..<min(end, reference.offset + 64 * 1_024)])
            guard let range = pdfFirstDictionaryRange(in: prefix),
                  let values = pdfCompressionValues(Data(prefix[range])),
                  ["/FlateDecode", "[/FlateDecode]"].contains(values["Filter"]?.filter { !$0.isWhitespace } ?? ""),
                  values["DecodeParms"] == nil,
                  let length = Int(values["Length"] ?? ""), length > 0,
                  let params = values["Params"].flatMap({ pdfCompressionValues(Data($0.utf8)) }),
                  let size = Int(params["Size"] ?? ""), size > 0, size <= Self.maximumAttachmentBytes,
                  let marker = prefix.range(of: Data("stream".utf8), in: range.upperBound..<prefix.count) else { continue }
            var start = marker.upperBound
            if start < prefix.count, prefix[start] == 13 { start += 1 }
            if start < prefix.count, prefix[start] == 10 { start += 1 }
            start += reference.offset
            guard length <= end - start else { continue }
            let encoded = Data(data[start..<(start + length)])
            candidates["\(length):\(size)", default: []].append(encoded)
        }
        return candidates.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }
}
