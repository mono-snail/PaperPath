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
    private static let maximumAttachmentCount = 256
    private static let maximumAttachmentBytes = 64 * 1_024 * 1_024
    private static let maximumDecodedBytes = 192 * 1_024 * 1_024

    func attachments(
        in url: URL,
        unlockPassword: String? = nil
    ) throws -> [PDFEmbeddedAttachmentSnapshot] {
        try decodedAttachmentPayloads(
            in: url,
            unlockPassword: unlockPassword
        ).map(\.snapshot)
    }

    func attachmentPayloads(
        in url: URL,
        unlockPassword: String? = nil
    ) throws -> [PDFEmbeddedAttachmentPayload] {
        try decodedAttachmentPayloads(
            in: url,
            unlockPassword: unlockPassword
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
            in: sourceURL
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
        LocalFileSecurity.applyCompleteProtection(
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
                try data.write(to: destination, options: .atomic)
                LocalFileSecurity.applyCompleteProtection(
                    to: destination,
                    fileManager: fileManager
                )
                let reopened = try Data(
                    contentsOf: destination,
                    options: .mappedIfSafe
                )
                guard reopened.count == payload.snapshot.byteCount,
                      Self.digest(reopened)
                        == payload.snapshot.checksum
                else {
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
            let value = document.page(at: index)?.label?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PDFPageLabelSnapshot(
                pageIndex: index,
                label: value?.isEmpty == false
                    ? value!
                    : String(index + 1),
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
        for pageIndex in 0..<document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex + 1),
                  let pageDictionary = page.dictionary
            else { continue }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(
                pageDictionary,
                "Annots",
                &annotations
            ),
                  let annotations
            else { continue }
            let count = min(CGPDFArrayGetCount(annotations), 4_096)
            for rawIndex in 0..<count {
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
            func walk(_ item: PDFOutline, depth: Int) {
                guard depth < 24,
                      outlineEntries.count < 2_000
                else { return }
                for index in 0..<item.numberOfChildren {
                    guard let child = item.child(at: index) else {
                        continue
                    }
                    let pageIndex = child.destination?.page.map {
                        document.index(for: $0)
                    } ?? NSNotFound
                    outlineEntries.append(
                        "\(depth)|\(child.label ?? "")|\(pageIndex)"
                    )
                    walk(child, depth: depth + 1)
                }
            }
            walk(root, depth: 0)
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
            annotationCounts: (0..<document.pageCount).map {
                document.page(at: $0)?.annotations.count ?? 0
            },
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
            formFieldCount += document.page(at: index)?.annotations
                .reduce(into: 0) { pageCount, annotation in
                let type = annotation.type?
                    .trimmingCharacters(
                        in: CharacterSet(charactersIn: "/")
                    )
                    .lowercased()
                if type == PDFAnnotationSubtype.widget.rawValue
                    .lowercased()
                    || annotation.fieldName != nil {
                    pageCount += 1
                }
                } ?? 0
        }
        let hasExplicitPageLabels = signature.pageLabels?
            .contains { $0.hasSuffix("|true") } ?? false

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
            annotationCount: signature.annotationCounts.reduce(0, +),
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

    private func decodedAttachmentPayloads(
        in url: URL,
        unlockPassword: String? = nil
    ) throws -> [PDFEmbeddedAttachmentPayload] {
        _ = try unlockedPDFDocument(
            at: url,
            password: unlockPassword
        )
        let document = try unlockedCGPDFDocument(
            at: url,
            password: unlockPassword
        )
        guard let catalog = document.catalog else {
            throw PaperPathError.unreadablePDF
        }

        var results: [PDFEmbeddedAttachmentPayload] = []
        var decodedByteCount = 0

        func append(
            fileSpec: CGPDFDictionaryRef,
            fallbackName: String?,
            description: String?,
            pageIndex: Int?,
            origin: PDFEmbeddedAttachmentOrigin
        ) {
            guard results.count < Self.maximumAttachmentCount,
                  let payload = attachmentPayload(
                      fileSpec: fileSpec,
                      fallbackName: fallbackName,
                      fallbackDescription: description,
                      pageIndex: pageIndex,
                      origin: origin,
                      decodedByteCount: &decodedByteCount
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
                results.append(payload)
            }
        }

        for pageIndex in 0..<document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex + 1),
                  let pageDictionary = page.dictionary
            else { continue }

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
            let count = min(CGPDFArrayGetCount(annotations), 4_096)
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
        return document
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
        guard depth < 16, remainingNodeBudget > 0 else { return }
        remainingNodeBudget -= 1

        if let names = pdfArray(in: node, key: "Names") {
            let count = min(CGPDFArrayGetCount(names), 8_192)
            var index = 0
            while index + 1 < count {
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
        decodedByteCount: inout Int
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

        if let declaredSize,
           declaredSize > Self.maximumAttachmentBytes {
            let snapshot = attachmentSnapshot(
                fileName: fileName,
                contentType: contentType,
                byteCount: declaredSize,
                checksum: "",
                description: description,
                pageIndex: pageIndex,
                origin: origin,
                isExtractable: false,
                limitation:
                    "Larger than the 64 MB local extraction limit"
            )
            return PDFEmbeddedAttachmentPayload(
                snapshot: snapshot,
                data: nil
            )
        }

        var format = CGPDFDataFormat.raw
        guard let copied = CGPDFStreamCopyData(stream, &format) else {
            return nil
        }
        let data = copied as Data
        let fitsPerFile = data.count <= Self.maximumAttachmentBytes
        let fitsTotal = decodedByteCount <= Self.maximumDecodedBytes
            - min(data.count, Self.maximumDecodedBytes)
        guard fitsPerFile, fitsTotal else {
            let reason = fitsPerFile
                ? "The PDF exceeds the 192 MB attachment review budget"
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
        decodedByteCount += data.count
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

    private func uniqueFileName(
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

    private func annotationColor(
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

private func decodePDFName(_ value: String) -> String {
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
