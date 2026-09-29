import CryptoKit
import Darwin
import Foundation
import PDFKit
import UIKit
import Vision

enum PrivacyCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case email
    case phone
    case identityNumber
    case socialSecurityNumber
    case taxIdentifier
    case passportNumber
    case bankAccount
    case paymentCard
    case ipAddress
    case date
    case address

    var title: String {
        switch self {
        case .email: "Email address".localizedUI
        case .phone: "Phone number".localizedUI
        case .identityNumber: "Identity number".localizedUI
        case .socialSecurityNumber:
            "Social security number".localizedUI
        case .taxIdentifier: "Tax identifier".localizedUI
        case .passportNumber: "Passport number".localizedUI
        case .bankAccount: "Bank account / IBAN".localizedUI
        case .paymentCard: "Payment card".localizedUI
        case .ipAddress: "IP address".localizedUI
        case .date: "Date".localizedUI
        case .address: "Address".localizedUI
        }
    }

    var systemImage: String {
        switch self {
        case .email: "envelope"
        case .phone: "phone"
        case .identityNumber: "person.text.rectangle"
        case .socialSecurityNumber: "person.badge.key"
        case .taxIdentifier: "building.columns"
        case .passportNumber: "globe.americas"
        case .bankAccount: "building.columns.fill"
        case .paymentCard: "creditcard"
        case .ipAddress: "network"
        case .date: "calendar"
        case .address: "mappin.and.ellipse"
        }
    }

    var isSelectedByDefault: Bool {
        switch self {
        case .ipAddress, .date, .address:
            false
        default:
            true
        }
    }

    var capabilityDescription: String {
        switch self {
        case .email:
            "Detects common email address formats".localizedUI
        case .phone:
            "Detects local and international phone numbers".localizedUI
        case .identityNumber:
            "Detects identity numbers near document labels".localizedUI
        case .socialSecurityNumber:
            "Detects social security numbers and labels".localizedUI
        case .taxIdentifier:
            "Detects tax numbers, TINs, and tax identifiers".localizedUI
        case .passportNumber:
            "Detects passport numbers near passport labels".localizedUI
        case .bankAccount:
            "Detects IBANs and labeled bank accounts".localizedUI
        case .paymentCard:
            "Flags only card numbers that pass Luhn validation".localizedUI
        case .ipAddress:
            "Detects IPv4 and IPv6 addresses".localizedUI
        case .date:
            "Detects dates in document text".localizedUI
        case .address:
            "Detects postal addresses in document text".localizedUI
        }
    }
}

enum PrivacyFindingConfidence: Int, Codable, Comparable, Sendable {
    case low
    case medium
    case high

    static func < (
        lhs: PrivacyFindingConfidence,
        rhs: PrivacyFindingConfidence
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum PrivacyFindingSource: String, Codable, Hashable, Sendable {
    case nativeText
    case opticalCharacterRecognition
}

struct PrivacyNormalizedRect: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init?(rect: CGRect, relativeTo cropBox: CGRect) {
        let rectComponents = [
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        ]
        let cropBoxComponents = [
            cropBox.origin.x,
            cropBox.origin.y,
            cropBox.size.width,
            cropBox.size.height
        ]
        guard cropBox.width > 0,
              cropBox.height > 0,
              rectComponents.allSatisfy(\.isFinite),
              cropBoxComponents.allSatisfy(\.isFinite),
              !rect.isNull,
              !rect.isEmpty,
              !cropBox.isNull,
              !cropBox.isEmpty
        else {
            return nil
        }
        let clipped = rect.standardized.intersection(cropBox.standardized)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        x = Double((clipped.minX - cropBox.minX) / cropBox.width)
        y = Double((clipped.minY - cropBox.minY) / cropBox.height)
        width = Double(clipped.width / cropBox.width)
        height = Double(clipped.height / cropBox.height)
    }

    init?(x: Double, y: Double, width: Double, height: Double) {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite),
              width > 0,
              height > 0
        else {
            return nil
        }
        let rect = CGRect(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(width),
            height: CGFloat(height)
        ).standardized.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard !rect.isNull, !rect.isEmpty else { return nil }
        self.x = Double(rect.minX)
        self.y = Double(rect.minY)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }

    var cgRect: CGRect {
        CGRect(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(width),
            height: CGFloat(height)
        )
    }
}

struct PrivacyFinding: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fingerprint: String
    let category: PrivacyCategory
    let pageIndex: Int
    let rawValue: String
    let maskedValue: String
    let confidence: PrivacyFindingConfidence
    let source: PrivacyFindingSource
    let normalizedBounds: [PrivacyNormalizedRect]
    let reason: String

    var isLocatable: Bool {
        !normalizedBounds.isEmpty
    }

    var isSelectedByDefault: Bool {
        isLocatable
            && category.isSelectedByDefault
            && confidence != .low
    }
}

struct PrivacySpatialTextObservation: Hashable, Sendable {
    let pageIndex: Int
    let text: String
    let normalizedBounds: PrivacyNormalizedRect
    let confidence: Float
}

enum PrivacyScanWarning:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Sendable {
    case textIndexWasTruncated
    case ocrTextHadNoSpatialData
    case ocrPageFailed
    case pageCouldNotBeRead

    var title: String {
        switch self {
        case .textIndexWasTruncated:
            "Text index was incomplete".localizedUI
        case .ocrTextHadNoSpatialData:
            "Some results cannot be located".localizedUI
        case .ocrPageFailed:
            "Some image text was not scanned".localizedUI
        case .pageCouldNotBeRead:
            "Some pages were not scanned".localizedUI
        }
    }

    var detail: String {
        switch self {
        case .textIndexWasTruncated:
            "The stored text index ended early. Review pages that may not have searchable text."
                .localizedUI
        case .ocrTextHadNoSpatialData:
            "Some OCR candidates have no page position and were not selected."
                .localizedUI
        case .ocrPageFailed:
            "On-device text recognition could not inspect one or more image pages."
                .localizedUI
        case .pageCouldNotBeRead:
            "PaperPath skipped one or more unreadable pages. Review the original before sharing."
                .localizedUI
        }
    }
}

struct PrivacyScanResult: Codable, Hashable, Sendable {
    let documentRevisionID: UUID?
    let startedAt: Date
    let completedAt: Date
    let pageCount: Int
    let findings: [PrivacyFinding]
    let warnings: Set<PrivacyScanWarning>

    var locatableFindings: [PrivacyFinding] {
        findings.filter(\.isLocatable)
    }

    var findingsByCategory: [PrivacyCategory: [PrivacyFinding]] {
        Dictionary(grouping: findings, by: \.category)
    }
}

struct PrivacyScanService {
    static let maximumPageCount = OCRResult.maximumPageCount

    private struct Candidate: Hashable {
        let category: PrivacyCategory
        let range: NSRange
        let value: String
        let confidence: PrivacyFindingConfidence
        let reason: String
    }

    private struct CandidateKey: Hashable {
        let category: PrivacyCategory
        let pageIndex: Int
        let normalizedValue: String
        let bounds: [PrivacyNormalizedRect]
    }

    private struct CandidateValueKey: Hashable {
        let category: PrivacyCategory
        let pageIndex: Int
        let normalizedValue: String
    }

    private static let emailPattern =
        #"(?<![A-Z0-9._%+\-])[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,63}(?![A-Z0-9_%+\-]|\.[A-Z0-9._%+\-])"#
    private static let paymentCardPattern =
        #"(?<![0-9])(?:[0-9][ -]?){12,18}[0-9](?![0-9])"#
    private static let chineseIdentityPattern =
        #"(?<![0-9])[1-9][0-9]{5}(?:18|19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9X](?![0-9])"#
    private static let socialSecurityPattern =
        #"(?<![0-9])[0-9]{3}-[0-9]{2}-[0-9]{4}(?![0-9])"#
    private static let ibanPattern =
        #"\b[A-Z]{2}[0-9]{2}(?:[ ]?[A-Z0-9]){11,30}\b"#
    private static let ipv4Pattern =
        #"\b(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}\b"#
    private static let ipv6Pattern =
        #"(?<![A-F0-9:])(?:[A-F0-9]{0,4}:){1,7}[A-F0-9]{0,4}(?![A-F0-9:])"#
    private static let ibanLengths: [String: Int] = [
        "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28,
        "BA": 20, "BE": 16, "BG": 22, "BH": 22, "BI": 27,
        "BR": 29, "BY": 28, "CH": 21, "CR": 22, "CY": 28,
        "CZ": 24, "DE": 22, "DJ": 27, "DK": 18, "DO": 28,
        "EE": 20, "EG": 29, "ES": 24, "FI": 18, "FK": 18,
        "FO": 18, "FR": 27, "GB": 22, "GE": 22, "GI": 23,
        "GL": 18, "GR": 27, "GT": 28, "HN": 28, "HR": 21,
        "HU": 28, "IE": 22, "IL": 23, "IQ": 23, "IS": 26,
        "IT": 27, "JO": 30, "KW": 30, "KZ": 20, "LB": 28,
        "LC": 32, "LI": 21, "LT": 20, "LU": 20, "LV": 21,
        "LY": 25, "MC": 27, "MD": 24, "ME": 22, "MK": 19,
        "MN": 20, "MR": 27, "MT": 31, "MU": 30, "NI": 28,
        "NL": 18, "NO": 15, "OM": 23, "PK": 24, "PL": 28,
        "PS": 29, "PT": 25, "QA": 29, "RO": 24, "RS": 22,
        "RU": 33, "SA": 24, "SC": 31, "SD": 18, "SE": 24,
        "SI": 19, "SK": 24, "SM": 27, "SO": 23, "ST": 25,
        "SV": 28, "TL": 23, "TN": 24, "TR": 26, "UA": 29,
        "VA": 22, "VG": 24, "XK": 20, "YE": 30
    ]

    private static let labeledPatterns: [
        (
            category: PrivacyCategory,
            pattern: String,
            reasonKey: String
        )
    ] = [
        (
            .socialSecurityNumber,
            #"(?:SSN|social\s+security(?:\s+number)?|社会保障号)\s*[:#：]?\s*([A-Z0-9][A-Z0-9 -]{4,24})"#,
            "Number near a social security label"
        ),
        (
            .taxIdentifier,
            #"(?:TIN|tax\s*(?:id|identifier|number)|税号|税务识别号)\s*[:#：]?\s*([A-Z0-9][A-Z0-9 -]{4,24})"#,
            "Number near a tax identifier label"
        ),
        (
            .passportNumber,
            #"(?:passport(?:\s*(?:no|number))?|护照(?:号码|号)?)\s*[:#：]?\s*([A-Z0-9][A-Z0-9 -]{4,20})"#,
            "Number near a passport label"
        ),
        (
            .identityNumber,
            #"(?:identity\s*(?:card|document|number)|national\s*id|身份证(?:号码|号)?|证件号)\s*[:#：]?\s*([A-Z0-9][A-Z0-9 -]{5,24})"#,
            "Number near an identity document label"
        ),
        (
            .bankAccount,
            #"(?:bank\s*account|account\s*(?:no|number)|银行账号|账户号码)\s*[:#：]?\s*([A-Z0-9][A-Z0-9 -]{5,34})"#,
            "Number near a bank account label"
        )
    ]
    private static let regularExpressions: [
        String: NSRegularExpression
    ] = {
        let patterns = [
            emailPattern,
            paymentCardPattern,
            chineseIdentityPattern,
            socialSecurityPattern,
            ibanPattern,
            ipv4Pattern,
            ipv6Pattern
        ] + labeledPatterns.map(\.pattern)
        return Dictionary(
            uniqueKeysWithValues: Set(patterns).compactMap { pattern in
                guard let expression = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                ) else {
                    return nil
                }
                return (pattern, expression)
            }
        )
    }()
    private static let dataDetector = try? NSDataDetector(
        types: [
            NSTextCheckingResult.CheckingType.phoneNumber,
            .date,
            .address
        ].reduce(0) { $0 | $1.rawValue }
    )

    static func spatialObservations(
        from result: OCRResult?,
        document: PDFDocument
    ) throws -> [PrivacySpatialTextObservation] {
        try Task.checkCancellation()
        guard let result, document.pageCount > 0 else { return [] }
        guard result.pages.count <= OCRResult.maximumPageCount else {
            throw PaperPathError.storageFailure(
                "The OCR result exceeds its safe processing limit."
            )
        }
        var observations: [PrivacySpatialTextObservation] = []
        observations.reserveCapacity(
            min(
                result.pages.reduce(0) { $0 + $1.blocks.count },
                OCRResult.maximumBlockCount
            )
        )
        var processedBlockCount = 0
        var processedTextBytes = 0
        for (pageOffset, page) in result.pages.enumerated()
        where (0..<document.pageCount).contains(page.pageIndex) {
            if pageOffset.isMultiple(of: 8) {
                try Task.checkCancellation()
            }
            let (nextBlockCount, blockCountOverflow) =
                processedBlockCount.addingReportingOverflow(
                    page.blocks.count
                )
            let pageTextBytes = page.blocks.reduce(0) {
                partial, block in
                let (next, overflow) = partial.addingReportingOverflow(
                    block.text.utf8.count
                )
                return overflow ? .max : next
            }
            let (nextTextBytes, textByteOverflow) =
                processedTextBytes.addingReportingOverflow(pageTextBytes)
            guard !blockCountOverflow,
                  nextBlockCount <= OCRResult.maximumBlockCount,
                  !textByteOverflow,
                  nextTextBytes <= OCRResult.maximumEncodedTextBytes
            else {
                throw PaperPathError.storageFailure(
                    "The OCR result exceeds its safe processing limit."
                )
            }
            processedBlockCount = nextBlockCount
            processedTextBytes = nextTextBytes
            guard let pdfPage = document.page(at: page.pageIndex) else {
                continue
            }
            let mediaBox = pdfPage.bounds(for: .mediaBox)
            let cropBox = pdfPage.bounds(for: .cropBox)
            guard mediaBox.isFinite,
                  cropBox.isFinite,
                  mediaBox.width > 0,
                  mediaBox.height > 0,
                  cropBox.width > 0,
                  cropBox.height > 0
            else {
                continue
            }
            let rotation = ((pdfPage.rotation % 360) + 360) % 360
            for (blockOffset, block) in page.blocks.enumerated() {
                if blockOffset.isMultiple(of: 128) {
                    try Task.checkCancellation()
                }
                let text = block.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let confidence = block.isUserCorrected
                    ? 1
                    : block.confidence
                let visionBounds = CGRect(
                    x: block.normalizedX,
                    y: block.normalizedY,
                    width: block.normalizedWidth,
                    height: block.normalizedHeight
                )
                let mediaNormalizedBounds = pdfNormalizedRect(
                    fromVisionBounds: visionBounds,
                    rotation: rotation
                )
                let absoluteBounds = CGRect(
                    x: mediaBox.minX
                        + mediaNormalizedBounds.minX * mediaBox.width,
                    y: mediaBox.minY
                        + mediaNormalizedBounds.minY * mediaBox.height,
                    width:
                        mediaNormalizedBounds.width * mediaBox.width,
                    height:
                        mediaNormalizedBounds.height * mediaBox.height
                )
                guard !text.isEmpty,
                      confidence.isFinite,
                      let bounds = PrivacyNormalizedRect(
                          rect: absoluteBounds,
                          relativeTo: cropBox
                      )
                else {
                    continue
                }
                observations.append(
                    PrivacySpatialTextObservation(
                        pageIndex: page.pageIndex,
                        text: text,
                        normalizedBounds: bounds,
                        confidence: Float(
                            min(1, max(0, confidence))
                        )
                    )
                )
            }
        }
        return observations
    }

    func scan(
        document: PDFDocument,
        textIndex: DocumentTextIndex? = nil,
        spatialOCR: [PrivacySpatialTextObservation] = [],
        documentRevisionID: UUID? = nil,
        performsOCRFallback: Bool = true,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> PrivacyScanResult {
        guard !document.isLocked else {
            throw PaperPathError.lockedPDF
        }
        guard document.pageCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Scan PDFs with up to 1,000 pages."
            )
        }
        guard spatialOCR.count <= OCRResult.maximumBlockCount else {
            throw PaperPathError.storageFailure(
                "The OCR result exceeds its safe processing limit."
            )
        }

        let startedAt = Date()
        var warnings: Set<PrivacyScanWarning> = []
        var findings: [PrivacyFinding] = []
        var seen: Set<CandidateKey> = []
        let spatialByPage = Dictionary(
            grouping: spatialOCR,
            by: \.pageIndex
        )
        let usableTextIndex: DocumentTextIndex?
        if let documentRevisionID,
           let indexedRevisionID = textIndex?.contentRevisionID,
           indexedRevisionID != documentRevisionID {
            usableTextIndex = nil
        } else {
            usableTextIndex = textIndex
        }
        let indexedByPage = (usableTextIndex?.pages ?? []).reduce(
            into: [Int: String]()
        ) { result, page in
            result[page.pageIndex] = page.text
        }
        var lastReportedProgressPercentage = -1
        let reportProgress: (Int) -> Void = { completedPages in
            guard Self.shouldReportProgress(
                completedPages: completedPages,
                totalPages: document.pageCount,
                lastReportedPercentage:
                    &lastReportedProgressPercentage
            ) else { return }
            progress?(completedPages, document.pageCount)
        }

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                warnings.insert(.pageCouldNotBeRead)
                reportProgress(pageIndex + 1)
                continue
            }

            let nativeText = page.string ?? ""
            let hasNativeText = !nativeText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            if hasNativeText {
                appendNativeFindings(
                    text: nativeText,
                    page: page,
                    pageIndex: pageIndex,
                    into: &findings,
                    seen: &seen
                )
            }

            if let observations = spatialByPage[pageIndex],
               !observations.isEmpty {
                for observation in observations {
                    appendSpatialOCRFindings(
                        observation: observation,
                        into: &findings,
                        seen: &seen
                    )
                }
            } else if !hasNativeText,
                      let indexedText = indexedByPage[pageIndex],
                      !indexedText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty {
                if usableTextIndex?.hasTruncatedContent == true {
                    warnings.insert(.textIndexWasTruncated)
                }
                warnings.insert(.ocrTextHadNoSpatialData)
                appendUnlocatedFindings(
                    text: indexedText,
                    pageIndex: pageIndex,
                    into: &findings,
                    seen: &seen
                )
            } else if !hasNativeText, performsOCRFallback {
                do {
                    try appendVisionOCRFindings(
                        page: page,
                        pageIndex: pageIndex,
                        into: &findings,
                        seen: &seen
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    warnings.insert(.ocrPageFailed)
                }
            }

            reportProgress(pageIndex + 1)
        }

        findings = coalescingCrossSourceDuplicates(in: findings)
        findings.sort {
            if $0.pageIndex != $1.pageIndex {
                return $0.pageIndex < $1.pageIndex
            }
            if $0.category != $1.category {
                return categoryIndex($0.category)
                    < categoryIndex($1.category)
            }
            return $0.fingerprint < $1.fingerprint
        }

        return PrivacyScanResult(
            documentRevisionID: documentRevisionID,
            startedAt: startedAt,
            completedAt: Date(),
            pageCount: document.pageCount,
            findings: findings,
            warnings: warnings
        )
    }

    static func progressPercentage(
        completedPages: Int,
        totalPages: Int
    ) -> Int {
        guard totalPages > 0 else { return 0 }
        return min(
            100,
            max(
                0,
                Int(
                    (
                        Double(completedPages)
                            / Double(totalPages) * 100
                    ).rounded(.down)
                )
            )
        )
    }

    static func shouldReportProgress(
        completedPages: Int,
        totalPages: Int,
        lastReportedPercentage: inout Int
    ) -> Bool {
        let percentage = progressPercentage(
            completedPages: completedPages,
            totalPages: totalPages
        )
        guard percentage > lastReportedPercentage
                || completedPages >= totalPages
        else {
            return false
        }
        lastReportedPercentage = percentage
        return true
    }

    func candidates(in text: String) -> [PrivacyFinding] {
        detectCandidates(in: text).map { candidate in
            makeFinding(
                candidate: candidate,
                pageIndex: 0,
                source: .nativeText,
                bounds: []
            )
        }
    }

    static func passesLuhnCheck(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard scalars.allSatisfy({
            Self.isASCIIDigit($0) || $0.value == 32 || $0.value == 45
        }) else {
            return false
        }
        let digits = scalars.compactMap {
            Self.isASCIIDigit($0) ? Int($0.value - 48) : nil
        }
        guard (13...19).contains(digits.count) else { return false }
        let checksum = digits.reversed().enumerated().reduce(0) {
            partial, pair in
            let (offset, digit) = pair
            guard offset.isMultiple(of: 2) == false else {
                return partial + digit
            }
            let doubled = digit * 2
            return partial + (doubled > 9 ? doubled - 9 : doubled)
        }
        return checksum.isMultiple(of: 10)
    }

    static func passesIBANCheck(_ value: String) -> Bool {
        let scalars = value.uppercased().unicodeScalars
        guard scalars.allSatisfy({
            Self.isASCIIAlphaNumeric($0) || $0.value == 32
        }) else {
            return false
        }
        let compact = String(
            String.UnicodeScalarView(scalars.filter { $0.value != 32 })
        )
        let countryCode = String(compact.prefix(2))
        guard let expectedLength = Self.ibanLengths[countryCode],
              compact.count == expectedLength,
              compact.prefix(2).unicodeScalars.allSatisfy(
                  Self.isASCIIUppercaseLetter
              ),
              compact.dropFirst(2).prefix(2).unicodeScalars.allSatisfy(
                  Self.isASCIIDigit
              )
        else {
            return false
        }

        let rearranged =
            String(compact.dropFirst(4)) + String(compact.prefix(4))
        var remainder = 0
        for scalar in rearranged.unicodeScalars {
            let token: String
            if Self.isASCIIDigit(scalar) {
                token = String(scalar.value - 48)
            } else if Self.isASCIIUppercaseLetter(scalar) {
                token = String(Int(scalar.value) - 55)
            } else {
                return false
            }
            for digit in token.utf8 {
                remainder = (remainder * 10 + Int(digit - 48)) % 97
            }
        }
        return remainder == 1
    }

    static func passesEmailCheck(_ value: String) -> Bool {
        guard value.utf8.count <= 254 else { return false }
        let parts = value.split(
            separator: "@",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[0].utf8.count <= 64,
              parts[0].first != ".",
              parts[0].last != ".",
              !parts[0].contains("..")
        else {
            return false
        }
        let labels = parts[1].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty
                && label.utf8.count <= 63
                && label.first != "-"
                && label.last != "-"
                && label.unicodeScalars.allSatisfy {
                    Self.isASCIIAlphaNumeric($0) || $0.value == 45
                }
        }
    }

    static func passesChineseIdentityCheck(_ value: String) -> Bool {
        let compact = value.uppercased()
        guard compact.count == 18 else { return false }
        let characters = Array(compact)
        let weights = [
            7, 9, 10, 5, 8, 4, 2, 1, 6,
            3, 7, 9, 10, 5, 8, 4, 2
        ]
        let checkCharacters = Array("10X98765432")
        var sum = 0
        for index in 0..<17 {
            guard let digit = characters[index].wholeNumberValue else {
                return false
            }
            sum += digit * weights[index]
        }
        guard characters[17] == checkCharacters[sum % 11],
              let year = Int(String(characters[6..<10])),
              let month = Int(String(characters[10..<12])),
              let day = Int(String(characters[12..<14]))
        else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day
            )
        ) else {
            return false
        }
        let resolved = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return date <= Date()
            && resolved.year == year
            && resolved.month == month
            && resolved.day == day
    }

    static func passesSocialSecurityCheck(_ value: String) -> Bool {
        let components = value.split(separator: "-")
        guard components.count == 3,
              components[0].count == 3,
              components[1].count == 2,
              components[2].count == 4,
              let area = Int(components[0]),
              let group = Int(components[1]),
              let serial = Int(components[2])
        else {
            return false
        }
        return area != 0
            && area != 666
            && area < 900
            && group != 0
            && serial != 0
    }

    static func passesIPv6Check(_ value: String) -> Bool {
        var address = in6_addr()
        return value.withCString {
            inet_pton(AF_INET6, $0, &address) == 1
        }
    }

    static func passesIPv4Check(_ value: String) -> Bool {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 4,
              components.allSatisfy({ component in
                  (1...3).contains(component.count)
                      && (component.count == 1 || component.first != "0")
                      && component.unicodeScalars.allSatisfy(
                          Self.isASCIIDigit
                      )
                      && (Int(component) ?? 256) <= 255
              })
        else {
            return false
        }
        var address = in_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &address) == 1
        }
    }

    static func maskedValue(
        _ value: String,
        category: PrivacyCategory
    ) -> String {
        switch category {
        case .email:
            let parts = value.split(
                separator: "@",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2 else { return genericMask(value) }
            let prefix = parts[0].first.map(String.init) ?? "*"
            return "\(prefix)***@\(parts[1])"
        case .phone, .identityNumber, .socialSecurityNumber,
             .taxIdentifier, .passportNumber, .bankAccount,
             .paymentCard:
            let suffix = value.filter {
                $0.isLetter || $0.isNumber
            }.suffix(4)
            return suffix.isEmpty ? "****" : "****\(suffix)"
        case .ipAddress:
            if let last = value.split(separator: ".").last,
               value.contains(".") {
                return "***.***.***.\(last)"
            }
            return "****:\(value.suffix(4))"
        case .date:
            return "****/**/**"
        case .address:
            let prefix = value.prefix(2)
            return prefix.isEmpty ? "****" : "\(prefix)****"
        }
    }

    private func appendNativeFindings(
        text: String,
        page: PDFPage,
        pageIndex: Int,
        into findings: inout [PrivacyFinding],
        seen: inout Set<CandidateKey>
    ) {
        let cropBox = page.bounds(for: .cropBox)
        for candidate in detectCandidates(in: text) {
            let bounds = normalizedBounds(
                for: candidate.range,
                on: page,
                cropBox: cropBox
            )
            append(
                candidate: candidate,
                pageIndex: pageIndex,
                source: .nativeText,
                bounds: bounds,
                into: &findings,
                seen: &seen
            )
        }
    }

    private func appendSpatialOCRFindings(
        observation: PrivacySpatialTextObservation,
        into findings: inout [PrivacyFinding],
        seen: inout Set<CandidateKey>
    ) {
        for candidate in detectCandidates(in: observation.text) {
            let confidence: PrivacyFindingConfidence
            if !observation.confidence.isFinite
                || observation.confidence < 0.5 {
                confidence = .low
            } else {
                confidence = min(candidate.confidence, .medium)
            }
            append(
                candidate: Candidate(
                    category: candidate.category,
                    range: candidate.range,
                    value: candidate.value,
                    confidence: confidence,
                    reason: candidate.reason
                ),
                pageIndex: observation.pageIndex,
                source: .opticalCharacterRecognition,
                bounds: [observation.normalizedBounds],
                into: &findings,
                seen: &seen
            )
        }
    }

    private func appendVisionOCRFindings(
        page: PDFPage,
        pageIndex: Int,
        into findings: inout [PrivacyFinding],
        seen: inout Set<CandidateKey>
    ) throws {
        try Task.checkCancellation()
        let cropSize = page.bounds(for: .cropBox).standardized.size
        guard cropSize.width.isFinite,
              cropSize.height.isFinite,
              cropSize.width > 0,
              cropSize.height > 0
        else {
            return
        }
        let rotation = normalizedRotation(page.rotation)
        let displayedSize: CGSize
        if rotation == 90 || rotation == 270 {
            displayedSize = CGSize(
                width: cropSize.height,
                height: cropSize.width
            )
        } else {
            displayedSize = cropSize
        }
        let maximumDimension: CGFloat = 3_000
        let requestedScale = min(
            3,
            maximumDimension / max(
                displayedSize.width,
                displayedSize.height
            )
        )
        let scale = max(0.01, requestedScale)
        let imageSize = CGSize(
            width: max(1, floor(displayedSize.width * scale)),
            height: max(1, floor(displayedSize.height * scale))
        )
        try autoreleasepool {
            let image = page.thumbnail(of: imageSize, for: .cropBox)
            guard let cgImage = image.cgImage else { return }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.minimumTextHeight = 0.004
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: .up,
                options: [:]
            )
            try handler.perform([request])
            try Task.checkCancellation()

            for observation in request.results ?? [] {
                guard let recognized = observation.topCandidates(1).first else {
                    continue
                }
                for candidate in detectCandidates(in: recognized.string) {
                    guard let textRange = Range(
                        candidate.range,
                        in: recognized.string
                    ),
                    let rectangle = try? recognized.boundingBox(
                        for: textRange
                    )
                    else {
                        continue
                    }
                    let pdfBounds = Self.pdfNormalizedRect(
                        fromVisionBounds: rectangle.boundingBox,
                        rotation: rotation
                    )
                    guard let bounds = PrivacyNormalizedRect(
                        x: Double(pdfBounds.minX),
                        y: Double(pdfBounds.minY),
                        width: Double(pdfBounds.width),
                        height: Double(pdfBounds.height)
                    ) else {
                        continue
                    }
                    let confidence: PrivacyFindingConfidence
                    if recognized.confidence < 0.5 {
                        confidence = .low
                    } else {
                        confidence = min(candidate.confidence, .medium)
                    }
                    append(
                        candidate: Candidate(
                            category: candidate.category,
                            range: candidate.range,
                            value: candidate.value,
                            confidence: confidence,
                            reason: AppLocalization.format(
                                "%@, detected with on-device OCR",
                                candidate.reason
                            )
                        ),
                        pageIndex: pageIndex,
                        source: .opticalCharacterRecognition,
                        bounds: [bounds],
                        into: &findings,
                        seen: &seen
                    )
                }
            }
        }
    }

    private func appendUnlocatedFindings(
        text: String,
        pageIndex: Int,
        into findings: inout [PrivacyFinding],
        seen: inout Set<CandidateKey>
    ) {
        for candidate in detectCandidates(in: text) {
            append(
                candidate: Candidate(
                    category: candidate.category,
                    range: candidate.range,
                    value: candidate.value,
                    confidence: .low,
                    reason: AppLocalization.format(
                        "%@, OCR text has no position",
                        candidate.reason
                    )
                ),
                pageIndex: pageIndex,
                source: .opticalCharacterRecognition,
                bounds: [],
                into: &findings,
                seen: &seen
            )
        }
    }

    private func append(
        candidate: Candidate,
        pageIndex: Int,
        source: PrivacyFindingSource,
        bounds: [PrivacyNormalizedRect],
        into findings: inout [PrivacyFinding],
        seen: inout Set<CandidateKey>
    ) {
        let normalizedValue = normalize(candidate.value)
        let key = CandidateKey(
            category: candidate.category,
            pageIndex: pageIndex,
            normalizedValue: normalizedValue,
            bounds: bounds
        )
        guard !normalizedValue.isEmpty, seen.insert(key).inserted else {
            return
        }
        findings.append(
            makeFinding(
                candidate: candidate,
                pageIndex: pageIndex,
                source: source,
                bounds: bounds
            )
        )
    }

    private func makeFinding(
        candidate: Candidate,
        pageIndex: Int,
        source: PrivacyFindingSource,
        bounds: [PrivacyNormalizedRect]
    ) -> PrivacyFinding {
        let normalizedValue = normalize(candidate.value)
        let fingerprintSource = [
            candidate.category.rawValue,
            String(pageIndex),
            normalizedValue,
            bounds.map {
                "\($0.x),\($0.y),\($0.width),\($0.height)"
            }.joined(separator: ";")
        ].joined(separator: "|")
        let digest = SHA256.hash(
            data: Data(fingerprintSource.utf8)
        )
        let fingerprint = digest.map {
            String(format: "%02x", $0)
        }.joined()

        return PrivacyFinding(
            id: UUID(),
            fingerprint: fingerprint,
            category: candidate.category,
            pageIndex: pageIndex,
            rawValue: candidate.value,
            maskedValue: Self.maskedValue(
                candidate.value,
                category: candidate.category
            ),
            confidence: candidate.confidence,
            source: source,
            normalizedBounds: bounds,
            reason: candidate.reason
        )
    }

    private func normalizedBounds(
        for range: NSRange,
        on page: PDFPage,
        cropBox: CGRect
    ) -> [PrivacyNormalizedRect] {
        guard let selection = page.selection(for: range) else {
            return []
        }
        let lineSelections = selection.selectionsByLine()
        let selections = lineSelections.isEmpty ? [selection] : lineSelections
        return selections.compactMap {
            PrivacyNormalizedRect(
                rect: $0.bounds(for: page),
                relativeTo: cropBox
            )
        }
    }

    private func detectCandidates(in text: String) -> [Candidate] {
        guard !text.isEmpty else { return [] }
        var candidates: [Candidate] = []

        appendRegexMatches(
            pattern: Self.emailPattern,
            text: text,
            category: .email,
            confidence: .high,
            reason: "Email address format".localizedUI,
            validator: Self.passesEmailCheck,
            into: &candidates
        )

        appendDataDetectorMatches(in: text, into: &candidates)

        appendRegexMatches(
            pattern: Self.paymentCardPattern,
            text: text,
            category: .paymentCard,
            confidence: .high,
            reason: "Payment card number passed Luhn validation"
                .localizedUI,
            validator: Self.passesLuhnCheck,
            into: &candidates
        )
        appendRegexMatches(
            pattern: Self.chineseIdentityPattern,
            text: text,
            category: .identityNumber,
            confidence: .high,
            reason: "Identity number passed checksum validation"
                .localizedUI,
            validator: Self.passesChineseIdentityCheck,
            into: &candidates
        )
        appendRegexMatches(
            pattern: Self.socialSecurityPattern,
            text: text,
            category: .socialSecurityNumber,
            confidence: .high,
            reason: "Valid social security number format".localizedUI,
            validator: Self.passesSocialSecurityCheck,
            into: &candidates
        )
        appendRegexMatches(
            pattern: Self.ibanPattern,
            text: text,
            category: .bankAccount,
            confidence: .high,
            reason: "IBAN passed checksum validation".localizedUI,
            validator: Self.passesIBANCheck,
            into: &candidates
        )
        appendRegexMatches(
            pattern: Self.ipv4Pattern,
            text: text,
            category: .ipAddress,
            confidence: .high,
            reason: "IPv4 address format".localizedUI,
            validator: Self.passesIPv4Check,
            into: &candidates
        )
        appendRegexMatches(
            pattern: Self.ipv6Pattern,
            text: text,
            category: .ipAddress,
            confidence: .medium,
            reason: "IPv6 address format".localizedUI,
            validator: Self.passesIPv6Check,
            into: &candidates
        )

        for labeledPattern in Self.labeledPatterns {
            appendRegexMatches(
                pattern: labeledPattern.pattern,
                text: text,
                category: labeledPattern.category,
                confidence: .high,
                reason: labeledPattern.reasonKey.localizedUI,
                captureGroup: 1,
                into: &candidates
            )
        }

        return removeOverlappingDuplicates(candidates)
    }

    private func appendDataDetectorMatches(
        in text: String,
        into candidates: inout [Candidate]
    ) {
        guard let detector = Self.dataDetector else {
            return
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(
            in: text,
            options: [],
            range: fullRange
        )
        for result in matches {
            guard let range = Range(result.range, in: text) else {
                continue
            }
            let value = String(text[range])
            let category: PrivacyCategory
            let confidence: PrivacyFindingConfidence
            let reason: String
            switch result.resultType {
            case .phoneNumber:
                category = .phone
                confidence = .high
                reason = "System phone number detection".localizedUI
            case .date:
                category = .date
                confidence = .medium
                reason = "System date detection".localizedUI
            case .address:
                category = .address
                confidence = .medium
                reason = "System address detection".localizedUI
            default:
                continue
            }
            candidates.append(
                Candidate(
                    category: category,
                    range: result.range,
                    value: value,
                    confidence: confidence,
                    reason: reason
                )
            )
        }
    }

    private func appendRegexMatches(
        pattern: String,
        text: String,
        category: PrivacyCategory,
        confidence: PrivacyFindingConfidence,
        reason: String,
        captureGroup: Int = 0,
        validator: ((String) -> Bool)? = nil,
        into candidates: inout [Candidate]
    ) {
        guard let expression = Self.regularExpressions[pattern] else {
            return
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(
            in: text,
            options: [],
            range: fullRange
        )
        for result in matches {
            guard captureGroup < result.numberOfRanges else {
                continue
            }
            let range = result.range(at: captureGroup)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: text)
            else {
                continue
            }
            let value = String(text[swiftRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, validator?(value) ?? true else {
                continue
            }
            candidates.append(
                Candidate(
                    category: category,
                    range: NSRange(swiftRange, in: text),
                    value: value,
                    confidence: confidence,
                    reason: reason
                )
            )
        }
    }

    private func removeOverlappingDuplicates(
        _ candidates: [Candidate]
    ) -> [Candidate] {
        var result: [Candidate] = []
        let sorted = candidates.sorted {
            if $0.confidence != $1.confidence {
                return $0.confidence > $1.confidence
            }
            if $0.range.length != $1.range.length {
                return $0.range.length > $1.range.length
            }
            return deduplicationPriority($0.category)
                < deduplicationPriority($1.category)
        }
        for candidate in sorted {
            let normalizedValue = normalize(candidate.value)
            let duplicate = result.contains {
                categoriesMayDuplicate(
                    $0.category,
                    candidate.category
                )
                    && normalize($0.value) == normalizedValue
                    && NSIntersectionRange(
                        $0.range,
                        candidate.range
                    ).length > 0
            }
            if !duplicate {
                result.append(candidate)
            }
        }
        return result
    }

    private func coalescingCrossSourceDuplicates(
        in findings: [PrivacyFinding]
    ) -> [PrivacyFinding] {
        var result: [PrivacyFinding] = []
        var indicesByValue: [CandidateValueKey: [Int]] = [:]
        result.reserveCapacity(findings.count)

        for finding in findings {
            let key = CandidateValueKey(
                category: finding.category,
                pageIndex: finding.pageIndex,
                normalizedValue: normalize(finding.rawValue)
            )
            let matchingIndex = indicesByValue[key]?.first {
                findingsShareRegion(result[$0], finding)
            }
            if let matchingIndex {
                if findingIsPreferred(
                    finding,
                    over: result[matchingIndex]
                ) {
                    result[matchingIndex] = finding
                }
                continue
            }
            indicesByValue[key, default: []].append(result.count)
            result.append(finding)
        }
        return result
    }

    private func findingsShareRegion(
        _ lhs: PrivacyFinding,
        _ rhs: PrivacyFinding
    ) -> Bool {
        guard !lhs.normalizedBounds.isEmpty,
              !rhs.normalizedBounds.isEmpty
        else {
            return true
        }
        return lhs.normalizedBounds.contains { left in
            rhs.normalizedBounds.contains { right in
                let leftRect = left.cgRect
                let rightRect = right.cgRect
                let intersection = leftRect.intersection(rightRect)
                guard !intersection.isNull,
                      !intersection.isEmpty
                else {
                    return false
                }
                let intersectionArea =
                    intersection.width * intersection.height
                let smallerArea = min(
                    leftRect.width * leftRect.height,
                    rightRect.width * rightRect.height
                )
                return smallerArea > 0
                    && intersectionArea / smallerArea >= 0.5
            }
        }
    }

    private func findingIsPreferred(
        _ candidate: PrivacyFinding,
        over existing: PrivacyFinding
    ) -> Bool {
        if candidate.isLocatable != existing.isLocatable {
            return candidate.isLocatable
        }
        if candidate.source != existing.source {
            return candidate.source == .nativeText
        }
        if candidate.confidence != existing.confidence {
            return candidate.confidence > existing.confidence
        }
        return candidate.normalizedBounds.reduce(0) {
            $0 + $1.width * $1.height
        } < existing.normalizedBounds.reduce(0) {
            $0 + $1.width * $1.height
        }
    }

    private func categoriesMayDuplicate(
        _ lhs: PrivacyCategory,
        _ rhs: PrivacyCategory
    ) -> Bool {
        guard lhs != rhs else { return true }
        let numericIdentifiers: Set<PrivacyCategory> = [
            .identityNumber,
            .socialSecurityNumber,
            .taxIdentifier,
            .passportNumber,
            .bankAccount,
            .paymentCard
        ]
        if numericIdentifiers.contains(lhs),
           numericIdentifiers.contains(rhs) {
            return true
        }
        return (lhs == .phone && numericIdentifiers.contains(rhs))
            || (rhs == .phone && numericIdentifiers.contains(lhs))
    }

    private func deduplicationPriority(
        _ category: PrivacyCategory
    ) -> Int {
        switch category {
        case .identityNumber: 0
        case .socialSecurityNumber: 1
        case .taxIdentifier: 2
        case .passportNumber: 3
        case .bankAccount: 4
        case .paymentCard: 5
        case .email: 6
        case .phone: 7
        case .ipAddress: 8
        case .date: 9
        case .address: 10
        }
    }

    private func normalize(_ value: String) -> String {
        return String(
            value.folding(
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive
                ],
                locale: nil
            )
            .filter { $0.isLetter || $0.isNumber }
        ).lowercased()
    }

    private static func isASCIIDigit(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        (48...57).contains(scalar.value)
    }

    private static func isASCIIUppercaseLetter(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        (65...90).contains(scalar.value)
    }

    private static func isASCIIAlphaNumeric(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        isASCIIDigit(scalar)
            || isASCIIUppercaseLetter(scalar)
            || (97...122).contains(scalar.value)
    }

    private static func genericMask(_ value: String) -> String {
        value.isEmpty ? "****" : "\(value.prefix(1))***"
    }

    private func categoryIndex(_ category: PrivacyCategory) -> Int {
        Self.categoryIndex(category)
    }

    private static func categoryIndex(
        _ category: PrivacyCategory
    ) -> Int {
        PrivacyCategory.allCases.firstIndex(of: category) ?? .max
    }

    private func normalizedRotation(_ rotation: Int) -> Int {
        ((rotation % 360) + 360) % 360
    }

    private static func pdfNormalizedRect(
        fromVisionBounds rect: CGRect,
        rotation: Int
    ) -> CGRect {
        switch rotation {
        case 90:
            return CGRect(
                x: 1 - rect.maxY,
                y: rect.minX,
                width: rect.height,
                height: rect.width
            )
        case 180:
            return CGRect(
                x: 1 - rect.maxX,
                y: 1 - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        case 270:
            return CGRect(
                x: rect.minY,
                y: 1 - rect.maxX,
                width: rect.height,
                height: rect.width
            )
        default:
            return rect
        }
    }
}

private extension CGRect {
    var isFinite: Bool {
        [minX, minY, width, height].allSatisfy(\.isFinite)
    }
}
