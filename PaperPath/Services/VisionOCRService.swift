import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PDFKit
import UIKit
@preconcurrency import Vision

struct OCRCheckpointIdentity: Codable, Hashable, Sendable {
    static let currentEngineVersion = 1

    let recordID: UUID
    let revisionID: UUID
    let pageCount: Int
    let configuration: OCRRecognitionConfiguration
    var engineVersion = currentEngineVersion
    var systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
}

struct OCRCheckpoint: Sendable {
    let identity: OCRCheckpointIdentity
    let pages: [OCRPageResult]
}

struct OCRRecoverySummary: Hashable, Sendable {
    let identity: OCRCheckpointIdentity
    let completedPageIndices: [Int]
    let damagedPageCount: Int

    var completedPageCount: Int { completedPageIndices.count }
}

struct VisionOCRService: Sendable {
    private let maximumImageDimension: CGFloat = 2_200
    private let retryImageDimension: CGFloat = 3_200
    private static let maximumBlocksPerPage = 4_096
    private static let maximumBlockTextBytes = 16 * 1_024
    private static let maximumPageTextBytes = 1 * 1_024 * 1_024
    private static let maximumPageDimension: CGFloat = 200_000
    private static let enhancementContext = CIContext(
        options: [
            .cacheIntermediates: false,
            .priorityRequestLow: false
        ]
    )

    func releaseCachedResources() {
        Self.enhancementContext.clearCaches()
    }

    func recognize(
        url: URL,
        configuration: OCRRecognitionConfiguration = .automatic,
        checkpoint: OCRCheckpoint? = nil,
        onPageCompleted: @escaping @Sendable (OCRPageResult) async throws -> Void = { _ in },
        progress: @escaping PDFProgressHandler = { _ in }
    ) async throws -> OCRResult {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let document = PDFDocument(url: url) else {
                throw PaperPathError.unreadablePDF
            }
            guard !document.isLocked else {
                throw PaperPathError.lockedPDF
            }
            guard document.pageCount > 0 else {
                throw PaperPathError.unreadablePDF
            }
            guard document.pageCount <= OCRResult.maximumPageCount else {
                throw PaperPathError.insufficientSelection(
                    "Recognize up to 1,000 pages at once."
                )
            }

            let appliedConfiguration = try validated(
                configuration
            )
            if let checkpoint {
                guard checkpoint.identity.configuration == appliedConfiguration,
                      checkpoint.identity.pageCount == document.pageCount,
                      checkpoint.identity.engineVersion
                        == OCRCheckpointIdentity.currentEngineVersion,
                      checkpoint.identity.systemVersion
                        == ProcessInfo.processInfo.operatingSystemVersionString,
                      checkpoint.pages.count <= document.pageCount,
                      Set(checkpoint.pages.map(\.pageIndex)).count == checkpoint.pages.count,
                      checkpoint.pages.allSatisfy({
                          (0..<document.pageCount).contains($0.pageIndex)
                      })
                else { throw PaperPathError.invalidPage }
            }
            let savedPages = Dictionary(
                uniqueKeysWithValues: (checkpoint?.pages ?? []).map {
                    ($0.pageIndex, $0)
                }
            )
            var pages: [OCRPageResult] = []
            pages.reserveCapacity(min(document.pageCount, 128))
            var totalBlockCount = 0
            var totalTextBytes = 0
            var lastReportedPercent = -1
            var completedPageCount = savedPages.count
            progress(Double(completedPageCount) / Double(document.pageCount))
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                let result: OCRPageResult
                if let saved = savedPages[index] {
                    result = saved
                } else {
                    guard let page = document.page(at: index) else {
                        throw PaperPathError.invalidPage
                    }
                    result = try await recognize(
                        page: page,
                        pageIndex: index,
                        configuration: appliedConfiguration
                    )
                }
                try Task.checkCancellation()
                let blockTextBytes = result.blocks.reduce(0) {
                    partial, block in
                    let (sum, overflow) = partial.addingReportingOverflow(
                        block.text.utf8.count
                    )
                    return overflow ? .max : sum
                }
                let (pageTextBytes, pageTextOverflow) =
                    result.text.utf8.count.addingReportingOverflow(
                        blockTextBytes
                    )
                let (nextTextBytes, textOverflow) =
                    totalTextBytes.addingReportingOverflow(pageTextBytes)
                let (nextBlockCount, blockOverflow) =
                    totalBlockCount.addingReportingOverflow(
                        result.blocks.count
                    )
                guard !pageTextOverflow,
                      !textOverflow,
                      !blockOverflow,
                      nextTextBytes
                        <= OCRResult.maximumEncodedTextBytes,
                      nextBlockCount <= OCRResult.maximumBlockCount
                else {
                    throw PaperPathError.insufficientSelection(
                        "This document contains too much recognized text to process safely."
                    )
                }
                if savedPages[index] == nil {
                    try await onPageCompleted(result)
                    try Task.checkCancellation()
                    completedPageCount += 1
                }
                pages.append(result)
                totalTextBytes = nextTextBytes
                totalBlockCount = nextBlockCount
                let fraction = Double(completedPageCount)
                    / Double(document.pageCount)
                let percent = Int((fraction * 100).rounded(.down))
                if percent > lastReportedPercent {
                    lastReportedPercent = percent
                    progress(fraction)
                }
            }
            try Task.checkCancellation()
            return OCRResult(
                pages: pages,
                configuration: appliedConfiguration
            )
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private func recognize(
        page: PDFPage,
        pageIndex: Int,
        configuration: OCRRecognitionConfiguration
    ) async throws -> OCRPageResult {
        let bounds = page.bounds(for: .mediaBox)
        guard Self.hasValidPageGeometry(bounds) else {
            throw PaperPathError.invalidPage
        }

        guard let primary = try await recognizeRenderedPage(
            page,
            bounds: bounds,
            longestEdge: maximumImageDimension,
            pageIndex: pageIndex,
            configuration: configuration,
            pass: .standard
        ) else {
            throw PaperPathError.unreadableImage
        }
        guard shouldRetry(primary) else { return primary }
        try Task.checkCancellation()

        guard let enhanced = try await recognizeRenderedPage(
            page,
            bounds: bounds,
            longestEdge: retryImageDimension,
            pageIndex: pageIndex,
            configuration: configuration,
            pass: .enhanced
        )
        else { return primary }
        return recognitionScore(enhanced)
            > recognitionScore(primary) + 0.012
            ? enhanced
            : primary
    }

    private func recognizeRenderedPage(
        _ page: PDFPage,
        bounds: CGRect,
        longestEdge: CGFloat,
        pageIndex: Int,
        configuration: OCRRecognitionConfiguration,
        pass: OCRRecognitionPass
    ) async throws -> OCRPageResult? {
        try Task.checkCancellation()
        guard let image = autoreleasepool(invoking: {
            () -> CGImage? in
            guard let rendered = renderedImage(
                page,
                bounds: bounds,
                longestEdge: longestEdge
            ) else { return nil }
            switch pass {
            case .standard:
                return rendered
            case .enhanced:
                return enhancedTextImage(rendered)
            }
        }) else { return nil }
        return try await recognize(
            image: image,
            pageIndex: pageIndex,
            configuration: configuration,
            pass: pass
        )
    }

    private func recognize(
        image: CGImage,
        pageIndex: Int,
        configuration: OCRRecognitionConfiguration,
        pass: OCRRecognitionPass
    ) async throws -> OCRPageResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage =
            configuration.languageMode == .automatic
        request.recognitionLanguages =
            configuration.languageIdentifiers
        request.customWords = configuration.customWords
        request.minimumTextHeight = 0.003

        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try handler.perform([request])
            } onCancel: {
                request.cancel()
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()

        var candidates: [OCRTextBlock] = []
        let observations = request.results ?? []
        guard observations.count <= Self.maximumBlocksPerPage else {
            throw PaperPathError.insufficientSelection(
                "This page contains too many text regions to recognize safely."
            )
        }
        candidates.reserveCapacity(observations.count)
        var pageTextBytes = 0
        for (index, observation) in observations.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }
            let text = candidate.string.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { continue }
            let textBytes = text.utf8.count
            guard textBytes <= Self.maximumBlockTextBytes else {
                throw PaperPathError.insufficientSelection(
                    "This page contains too much recognized text to process safely."
                )
            }
            let (nextPageTextBytes, overflow) = pageTextBytes
                .addingReportingOverflow(textBytes + 1)
            guard !overflow,
                  nextPageTextBytes <= Self.maximumPageTextBytes
            else {
                throw PaperPathError.insufficientSelection(
                    "This page contains too much recognized text to process safely."
                )
            }
            let rawBounds = observation.boundingBox
            guard rawBounds.origin.x.isFinite,
                  rawBounds.origin.y.isFinite,
                  rawBounds.width.isFinite,
                  rawBounds.height.isFinite
            else { continue }
            let bounds = rawBounds
                .standardized
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let confidence = Double(candidate.confidence)
            guard bounds.width > 0,
                  bounds.height > 0,
                  confidence.isFinite,
                  (0...1).contains(confidence)
            else { continue }
            candidates.append(
                OCRTextBlock(
                    text: text,
                    confidence: confidence,
                    normalizedX: bounds.origin.x,
                    normalizedY: bounds.origin.y,
                    normalizedWidth: bounds.width,
                    normalizedHeight: bounds.height
                )
            )
            pageTextBytes = nextPageTextBytes
        }
        try Task.checkCancellation()
        let ordered = readingOrder(candidates)
        try Task.checkCancellation()
        let text = ordered.map(\.text).joined(separator: "\n")
        let confidence: Double
        if ordered.isEmpty {
            confidence = 0
        } else {
            let totalWeight = ordered.reduce(0) {
                $0 + max(1, $1.text.count)
            }
            confidence = ordered.reduce(0) {
                $0 + $1.confidence * Double(max(1, $1.text.count))
            } / Double(max(1, totalWeight))
        }

        return OCRPageResult(
            pageIndex: pageIndex,
            text: text,
            confidence: confidence,
            blocks: ordered,
            recognitionPass: pass
        )
    }

    private func renderedImage(
        _ page: PDFPage,
        bounds: CGRect,
        longestEdge: CGFloat
    ) -> CGImage? {
        guard let sourcePage = page.pageRef else { return nil }
        let rotation = ((page.rotation % 360) + 360) % 360
        let swapsEdges = rotation == 90 || rotation == 270
        let sourceSize = CGSize(
            width: swapsEdges ? bounds.height : bounds.width,
            height: swapsEdges ? bounds.width : bounds.height
        )
        let scale = min(
            longestEdge / max(sourceSize.width, sourceSize.height),
            4
        )
        let imageSize = CGSize(
            width: max(1, sourceSize.width * scale),
            height: max(1, sourceSize.height * scale)
        )
        let pixelWidth = Int(imageSize.width.rounded(.up))
        let pixelHeight = Int(imageSize.height.rounded(.up))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: pixelWidth,
            height: pixelHeight
        )
        context.setFillColor(UIColor.white.cgColor)
        context.fill(imageBounds)
        context.concatenate(
            sourcePage.getDrawingTransform(
                .mediaBox,
                rect: imageBounds,
                rotate: 0,
                preserveAspectRatio: true
            )
        )
        context.drawPDFPage(sourcePage)
        return context.makeImage()
    }

    private func enhancedTextImage(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let enhancer = CIFilter.documentEnhancer()
        enhancer.inputImage = input
        enhancer.amount = 0.72

        let controls = CIFilter.colorControls()
        controls.inputImage = enhancer.outputImage ?? input
        controls.saturation = 0
        controls.contrast = 1.16
        controls.brightness = 0.02

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = controls.outputImage ?? input
        sharpen.sharpness = 0.34
        guard let output = sharpen.outputImage else { return nil }
        return Self.enhancementContext.createCGImage(
            output,
            from: input.extent
        )
    }

    func shouldRetry(_ result: OCRPageResult) -> Bool {
        let characterCount = result.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .count
        let weakBlocks = result.blocks.filter {
            $0.confidence < 0.68
        }.count
        return result.confidence < 0.82
            || (
                characterCount < 80
                    && result.confidence < 0.9
            )
            || (
                !result.blocks.isEmpty
                    && weakBlocks * 4 >= result.blocks.count
            )
    }

    func recognitionScore(
        _ result: OCRPageResult
    ) -> Double {
        let characterValue = min(
            0.08,
            Double(result.text.count) / 8_000
        )
        let blockValue = min(
            0.04,
            Double(result.blocks.count) / 1_000
        )
        return result.confidence + characterValue + blockValue
    }

    func readingOrder(
        _ blocks: [OCRTextBlock]
    ) -> [OCRTextBlock] {
        guard hasTwoColumns(blocks) else {
            return blocks.sorted(by: lineOrder)
        }
        let spanning = blocks.filter {
            $0.normalizedWidth >= 0.58
                || (
                    $0.normalizedX < 0.35
                        && $0.normalizedX + $0.normalizedWidth > 0.65
                )
        }
        .sorted(by: lineOrder)
        let spanningIDs = Set(spanning.map(\.id))
        let narrow = blocks.filter {
            !spanningIDs.contains($0.id)
        }
        .sorted {
            let leftCenter = $0.normalizedY
                + $0.normalizedHeight * 0.5
            let rightCenter = $1.normalizedY
                + $1.normalizedHeight * 0.5
            if abs(leftCenter - rightCenter) > 0.001 {
                return leftCenter > rightCenter
            }
            return $0.normalizedX < $1.normalizedX
        }
        var result: [OCRTextBlock] = []
        result.reserveCapacity(blocks.count)
        var narrowIndex = 0
        for anchor in spanning {
            guard !Task.isCancelled else { return [] }
            let anchorY = anchor.normalizedY
                + anchor.normalizedHeight * 0.5
            var band: [OCRTextBlock] = []
            while narrowIndex < narrow.count {
                let block = narrow[narrowIndex]
                let centerY = block.normalizedY
                    + block.normalizedHeight * 0.5
                guard centerY >= anchorY else { break }
                band.append(block)
                narrowIndex += 1
            }
            result.append(contentsOf: columnOrder(band))
            result.append(anchor)
        }
        if narrowIndex < narrow.count {
            result.append(
                contentsOf: columnOrder(
                    Array(narrow[narrowIndex...])
                )
            )
        }
        return result
    }

    func hasTwoColumns(
        _ blocks: [OCRTextBlock]
    ) -> Bool {
        var leftCount = 0
        var rightCount = 0
        var leftLower = Double.greatestFiniteMagnitude
        var leftUpper = -Double.greatestFiniteMagnitude
        var rightLower = Double.greatestFiniteMagnitude
        var rightUpper = -Double.greatestFiniteMagnitude
        for block in blocks where block.normalizedWidth < 0.58 {
            guard !Task.isCancelled else { return false }
            let centerX = block.normalizedX
                + block.normalizedWidth * 0.5
            let upperY = block.normalizedY
                + block.normalizedHeight
            if centerX < 0.46 {
                leftCount += 1
                leftLower = min(leftLower, block.normalizedY)
                leftUpper = max(leftUpper, upperY)
            } else if centerX > 0.54 {
                rightCount += 1
                rightLower = min(rightLower, block.normalizedY)
                rightUpper = max(rightUpper, upperY)
            }
        }
        guard leftCount >= 3, rightCount >= 3 else {
            return false
        }
        let overlap = min(leftUpper, rightUpper)
            - max(leftLower, rightLower)
        return overlap > 0.22
    }

    func columnOrder(
        _ blocks: [OCRTextBlock]
    ) -> [OCRTextBlock] {
        var left: [OCRTextBlock] = []
        var right: [OCRTextBlock] = []
        left.reserveCapacity(blocks.count / 2)
        right.reserveCapacity(blocks.count / 2)
        for block in blocks {
            if block.normalizedX
                + block.normalizedWidth * 0.5 < 0.5 {
                left.append(block)
            } else {
                right.append(block)
            }
        }
        left.sort(by: lineOrder)
        right.sort(by: lineOrder)
        return left + right
    }

    func lineOrder(
        _ left: OCRTextBlock,
        _ right: OCRTextBlock
    ) -> Bool {
        let verticalTolerance = max(
            left.normalizedHeight,
            right.normalizedHeight
        ) * 0.55
        if abs(left.normalizedY - right.normalizedY)
            > verticalTolerance {
            return left.normalizedY > right.normalizedY
        }
        return left.normalizedX < right.normalizedX
    }

    func validated(
        _ configuration: OCRRecognitionConfiguration
    ) throws -> OCRRecognitionConfiguration {
        let customWords = configuration.customWords
            .map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .filter { !$0.isEmpty }
        let uniqueWords = customWords.reduce(into: [String]()) {
            result,
            word in
            guard !result.contains(where: {
                $0.caseInsensitiveCompare(word) == .orderedSame
            }) else { return }
            result.append(word)
        }
        guard uniqueWords.count <= 50,
              uniqueWords.allSatisfy({ $0.count <= 64 }),
              uniqueWords.reduce(0, { $0 + $1.count }) <= 2_048
        else {
            throw PaperPathError.insufficientSelection(
                "Use up to 50 custom terms, each no longer than 64 characters."
            )
        }

        let selectedLanguages = Array(
            Set(configuration.languageIdentifiers)
        ).sorted()
        if configuration.languageMode == .selected {
            guard (1...4).contains(selectedLanguages.count) else {
                throw PaperPathError.insufficientSelection(
                    "Choose between one and four recognition languages."
                )
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            let supported = Set(
                try request.supportedRecognitionLanguages()
            )
            guard selectedLanguages.allSatisfy(
                supported.contains
            ) else {
                throw PaperPathError.insufficientSelection(
                    "One of the selected languages is not available on this device."
                )
            }
        }
        return OCRRecognitionConfiguration(
            languageMode: configuration.languageMode,
            languageIdentifiers:
                configuration.languageMode == .selected
                    ? selectedLanguages
                    : [],
            customWords: uniqueWords
        )
    }

    private static func hasValidPageGeometry(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width > 0
            && bounds.height > 0
            && bounds.width <= maximumPageDimension
            && bounds.height <= maximumPageDimension
    }
}
