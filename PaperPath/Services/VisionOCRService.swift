import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PDFKit
import UIKit
@preconcurrency import Vision

struct VisionOCRService: Sendable {
    private let maximumImageDimension: CGFloat = 2_200
    private let retryImageDimension: CGFloat = 3_200
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
        progress: @escaping PDFProgressHandler = { _ in }
    ) async throws -> OCRResult {
        let task = Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url) else {
                throw PaperPathError.unreadablePDF
            }
            guard !document.isLocked else {
                throw PaperPathError.lockedPDF
            }

            let appliedConfiguration = try validated(
                configuration
            )
            var pages: [OCRPageResult] = []
            pages.reserveCapacity(min(document.pageCount, 128))
            progress(0)
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let result = try autoreleasepool {
                    try recognize(
                        page: page,
                        pageIndex: index,
                        configuration: appliedConfiguration
                    )
                }
                try Task.checkCancellation()
                pages.append(result)
                progress(
                    Double(index + 1)
                        / Double(max(1, document.pageCount))
                )
            }
            return OCRResult(
                pages: pages,
                configuration: appliedConfiguration
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func recognize(
        page: PDFPage,
        pageIndex: Int,
        configuration: OCRRecognitionConfiguration
    ) throws -> OCRPageResult {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            return OCRPageResult(pageIndex: pageIndex, text: "", confidence: 0)
        }

        guard let primaryImage = renderedImage(
            page,
            bounds: bounds,
            longestEdge: maximumImageDimension
        ) else {
            return OCRPageResult(pageIndex: pageIndex, text: "", confidence: 0)
        }
        let primary = try recognize(
            image: primaryImage,
            pageIndex: pageIndex,
            configuration: configuration,
            pass: .standard
        )
        guard shouldRetry(primary) else { return primary }
        try Task.checkCancellation()

        guard let retryImage = renderedImage(
            page,
            bounds: bounds,
            longestEdge: retryImageDimension
        ),
              let enhancedImage = enhancedTextImage(retryImage)
        else { return primary }
        let enhanced = try recognize(
            image: enhancedImage,
            pageIndex: pageIndex,
            configuration: configuration,
            pass: .enhanced
        )
        return recognitionScore(enhanced)
            > recognitionScore(primary) + 0.012
            ? enhanced
            : primary
    }

    private func recognize(
        image: CGImage,
        pageIndex: Int,
        configuration: OCRRecognitionConfiguration,
        pass: OCRRecognitionPass
    ) throws -> OCRPageResult {
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
        try handler.perform([request])
        if Task.isCancelled {
            request.cancel()
            throw CancellationError()
        }

        var candidates: [OCRTextBlock] = []
        let observations = request.results ?? []
        candidates.reserveCapacity(observations.count)
        for (index, observation) in observations.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }
            let bounds = observation.boundingBox
            candidates.append(
                OCRTextBlock(
                    text: candidate.string,
                    confidence: Double(candidate.confidence),
                    normalizedX: bounds.origin.x,
                    normalizedY: bounds.origin.y,
                    normalizedWidth: bounds.width,
                    normalizedHeight: bounds.height
                )
            )
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
        let scale = min(
            longestEdge / max(bounds.width, bounds.height),
            4
        )
        let imageSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        return page.thumbnail(
            of: imageSize,
            for: .mediaBox
        ).cgImage
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

    private func shouldRetry(_ result: OCRPageResult) -> Bool {
        let characterCount = result.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .count
        let weakBlocks = result.blocks.filter {
            $0.confidence < 0.68
        }.count
        return result.confidence < 0.82
            || characterCount < 80
            || (
                !result.blocks.isEmpty
                    && weakBlocks * 4 >= result.blocks.count
            )
    }

    private func recognitionScore(
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

    private func readingOrder(
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
        let narrow = blocks.filter {
            !spanning.contains($0)
        }
        var result: [OCRTextBlock] = []
        var upperY = 1.1
        for anchor in spanning {
            let anchorY = anchor.normalizedY
                + anchor.normalizedHeight * 0.5
            let band = narrow.filter {
                let centerY = $0.normalizedY
                    + $0.normalizedHeight * 0.5
                return centerY < upperY && centerY > anchorY
            }
            result.append(contentsOf: columnOrder(band))
            result.append(anchor)
            upperY = anchorY
        }
        result.append(
            contentsOf: columnOrder(
                narrow.filter {
                    $0.normalizedY
                        + $0.normalizedHeight * 0.5 < upperY
                }
            )
        )
        return result
    }

    private func hasTwoColumns(
        _ blocks: [OCRTextBlock]
    ) -> Bool {
        let candidates = blocks.filter {
            $0.normalizedWidth < 0.58
        }
        let left = candidates.filter {
            $0.normalizedX + $0.normalizedWidth * 0.5 < 0.46
        }
        let right = candidates.filter {
            $0.normalizedX + $0.normalizedWidth * 0.5 > 0.54
        }
        guard left.count >= 3, right.count >= 3 else {
            return false
        }
        let leftRange = verticalRange(left)
        let rightRange = verticalRange(right)
        let overlap = min(leftRange.upperBound, rightRange.upperBound)
            - max(leftRange.lowerBound, rightRange.lowerBound)
        return overlap > 0.22
    }

    private func verticalRange(
        _ blocks: [OCRTextBlock]
    ) -> ClosedRange<Double> {
        let lower = blocks.map(\.normalizedY).min() ?? 0
        let upper = blocks.map {
            $0.normalizedY + $0.normalizedHeight
        }.max() ?? 0
        return lower...upper
    }

    private func columnOrder(
        _ blocks: [OCRTextBlock]
    ) -> [OCRTextBlock] {
        let left = blocks.filter {
            $0.normalizedX + $0.normalizedWidth * 0.5 < 0.5
        }
        .sorted(by: lineOrder)
        let right = blocks.filter {
            $0.normalizedX + $0.normalizedWidth * 0.5 >= 0.5
        }
        .sorted(by: lineOrder)
        return left + right
    }

    private func lineOrder(
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

    private func validated(
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
}
