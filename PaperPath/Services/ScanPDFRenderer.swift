import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UIKit
@preconcurrency import Vision

enum ScanEnhancement: String, CaseIterable, Identifiable, Sendable {
    case original
    case color
    case document
    case grayscale
    case blackAndWhite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .color: return "Color"
        case .document: return "Document"
        case .grayscale: return "Grayscale"
        case .blackAndWhite: return "B&W"
        }
    }

    var symbol: String {
        switch self {
        case .original: return "circle"
        case .color: return "camera.filters"
        case .document: return "doc.text.image"
        case .grayscale: return "circle.lefthalf.filled"
        case .blackAndWhite: return "circle.righthalf.filled.inverse"
        }
    }
}

enum ScanCropCorner: String, CaseIterable, Identifiable, Sendable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft

    var id: String { rawValue }
}

struct ScanCropPoint: Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }
}

struct ScanCropQuad: Hashable, Sendable {
    var topLeft: ScanCropPoint
    var topRight: ScanCropPoint
    var bottomRight: ScanCropPoint
    var bottomLeft: ScanCropPoint

    static let fullFrame = Self(
        topLeft: ScanCropPoint(x: 0, y: 0),
        topRight: ScanCropPoint(x: 1, y: 0),
        bottomRight: ScanCropPoint(x: 1, y: 1),
        bottomLeft: ScanCropPoint(x: 0, y: 1)
    )

    var isValid: Bool {
        let doubledArea =
            topLeft.x * topRight.y
            - topRight.x * topLeft.y
            + topRight.x * bottomRight.y
            - bottomRight.x * topRight.y
            + bottomRight.x * bottomLeft.y
            - bottomLeft.x * bottomRight.y
            + bottomLeft.x * topLeft.y
            - topLeft.x * bottomLeft.y
        let area = abs(doubledArea) / 2
        guard area >= 0.04 else { return false }

        func edgeIsLongEnough(
            _ first: ScanCropPoint,
            _ second: ScanCropPoint
        ) -> Bool {
            let dx = second.x - first.x
            let dy = second.y - first.y
            return dx * dx + dy * dy >= 0.0025
        }
        guard edgeIsLongEnough(topLeft, topRight),
              edgeIsLongEnough(topRight, bottomRight),
              edgeIsLongEnough(bottomRight, bottomLeft),
              edgeIsLongEnough(bottomLeft, topLeft)
        else {
            return false
        }

        func cross(
            _ first: ScanCropPoint,
            _ second: ScanCropPoint,
            _ third: ScanCropPoint
        ) -> Double {
            (second.x - first.x) * (third.y - second.y)
                - (second.y - first.y) * (third.x - second.x)
        }
        let crosses = [
            cross(topLeft, topRight, bottomRight),
            cross(topRight, bottomRight, bottomLeft),
            cross(bottomRight, bottomLeft, topLeft),
            cross(bottomLeft, topLeft, topRight)
        ]
        let positive = crosses.allSatisfy { $0 > 0.0005 }
        let negative = crosses.allSatisfy { $0 < -0.0005 }
        return positive || negative
    }

    var isEffectivelyFullFrame: Bool {
        let tolerance = 0.005
        return abs(topLeft.x) <= tolerance
            && abs(topLeft.y) <= tolerance
            && abs(topRight.x - 1) <= tolerance
            && abs(topRight.y) <= tolerance
            && abs(bottomRight.x - 1) <= tolerance
            && abs(bottomRight.y - 1) <= tolerance
            && abs(bottomLeft.x) <= tolerance
            && abs(bottomLeft.y - 1) <= tolerance
    }

    var cacheKey: String {
        func scaled(_ value: Double) -> Int {
            Int((value * 1_000).rounded())
        }
        return [
            scaled(topLeft.x),
            scaled(topLeft.y),
            scaled(topRight.x),
            scaled(topRight.y),
            scaled(bottomRight.x),
            scaled(bottomRight.y),
            scaled(bottomLeft.x),
            scaled(bottomLeft.y)
        ].map { String($0) }
            .joined(separator: "-")
    }

    func point(for corner: ScanCropCorner) -> ScanCropPoint {
        switch corner {
        case .topLeft: return topLeft
        case .topRight: return topRight
        case .bottomRight: return bottomRight
        case .bottomLeft: return bottomLeft
        }
    }

    func moving(
        _ corner: ScanCropCorner,
        to point: ScanCropPoint
    ) -> ScanCropQuad {
        var candidate = self
        switch corner {
        case .topLeft: candidate.topLeft = point
        case .topRight: candidate.topRight = point
        case .bottomRight: candidate.bottomRight = point
        case .bottomLeft: candidate.bottomLeft = point
        }
        return candidate.isValid ? candidate : self
    }

    var rotatedClockwise: ScanCropQuad {
        func rotated(_ point: ScanCropPoint) -> ScanCropPoint {
            ScanCropPoint(
                x: 1 - point.y,
                y: point.x
            )
        }
        return ScanCropQuad(
            topLeft: rotated(bottomLeft),
            topRight: rotated(topLeft),
            bottomRight: rotated(topRight),
            bottomLeft: rotated(bottomRight)
        )
    }
}

struct ScanProcessingOptions: Hashable, Sendable {
    var enhancement: ScanEnhancement
    var autoCrop: Bool
    var removeShadows: Bool
    var cleanEdges: Bool
    var brightness: Double
    var contrast: Double
    var manualCrop: ScanCropQuad?

    init(
        enhancement: ScanEnhancement,
        autoCrop: Bool,
        removeShadows: Bool,
        cleanEdges: Bool,
        brightness: Double = 0,
        contrast: Double = 1,
        manualCrop: ScanCropQuad? = nil
    ) {
        self.enhancement = enhancement
        self.autoCrop = autoCrop
        self.removeShadows = removeShadows
        self.cleanEdges = cleanEdges
        self.brightness = min(0.5, max(-0.5, brightness))
        self.contrast = min(1.5, max(0.5, contrast))
        self.manualCrop =
            manualCrop?.isValid == true
                ? manualCrop
                : nil
    }

    var hasToneAdjustments: Bool {
        abs(brightness) > 0.001
            || abs(contrast - 1) > 0.001
    }

    static let document = Self(
        enhancement: .document,
        autoCrop: true,
        removeShadows: true,
        cleanEdges: true
    )

    static let original = Self(
        enhancement: .original,
        autoCrop: false,
        removeShadows: false,
        cleanEdges: false
    )
}

struct ScanPreviewResult: @unchecked Sendable {
    let image: UIImage
    let detectedDocument: Bool
    let cropQuad: ScanCropQuad?
}

struct ScanPageImage: @unchecked Sendable {
    let image: UIImage
    let processingOptions: ScanProcessingOptions?

    init(image: UIImage) {
        self.image = image
        processingOptions = nil
    }

    init(
        image: UIImage,
        processingOptions: ScanProcessingOptions
    ) {
        self.image = image
        self.processingOptions = processingOptions
    }
}

enum PaperTemplateKind: String, CaseIterable, Identifiable, Sendable {
    case blank
    case lined
    case grid
    case checklist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "Blank"
        case .lined: return "Lined"
        case .grid: return "Grid"
        case .checklist: return "Checklist"
        }
    }

    var symbol: String {
        switch self {
        case .blank: return "doc"
        case .lined: return "line.3.horizontal"
        case .grid: return "grid"
        case .checklist: return "checklist"
        }
    }
}

enum PaperTemplateSize: String, CaseIterable, Identifiable, Sendable {
    case letter
    case a4

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letter: return "US Letter"
        case .a4: return "A4"
        }
    }

    var dimensions: CGSize {
        switch self {
        case .letter: return CGSize(width: 612, height: 792)
        case .a4: return CGSize(width: 595, height: 842)
        }
    }
}

struct PaperTemplateRenderer: @unchecked Sendable {
    func render(
        kind: PaperTemplateKind,
        size: PaperTemplateSize,
        pageCount: Int,
        title: String,
        to destination: URL
    ) throws {
        let dimensions = size.dimensions
        let bounds = CGRect(origin: .zero, size: dimensions)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "PaperPath",
            kCGPDFContextTitle as String: title
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: bounds,
            format: format
        )

        do {
            try renderer.writePDF(to: destination) { context in
                for page in 0..<min(max(pageCount, 1), 50) {
                    context.beginPage()
                    let cg = context.cgContext
                    UIColor.white.setFill()
                    cg.fill(bounds)
                    drawTemplate(
                        kind,
                        in: bounds,
                        pageIndex: page,
                        context: cg
                    )
                }
            }
            LocalFileSecurity.applyCompleteProtection(to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.storageFailure(
                "The paper template could not be created."
            )
        }
    }

    private func drawTemplate(
        _ kind: PaperTemplateKind,
        in bounds: CGRect,
        pageIndex: Int,
        context: CGContext
    ) {
        let margin: CGFloat = 54
        let content = bounds.insetBy(dx: margin, dy: margin)
        let lineColor = UIColor(
            red: 0.24,
            green: 0.48,
            blue: 0.62,
            alpha: 0.18
        ).cgColor
        context.setStrokeColor(lineColor)
        context.setLineWidth(0.7)

        switch kind {
        case .blank:
            break
        case .lined:
            stride(
                from: content.minY + 18,
                through: content.maxY,
                by: 28
            ).forEach { y in
                context.move(to: CGPoint(x: content.minX, y: y))
                context.addLine(to: CGPoint(x: content.maxX, y: y))
            }
            context.strokePath()
        case .grid:
            stride(
                from: content.minX,
                through: content.maxX,
                by: 24
            ).forEach { x in
                context.move(to: CGPoint(x: x, y: content.minY))
                context.addLine(to: CGPoint(x: x, y: content.maxY))
            }
            stride(
                from: content.minY,
                through: content.maxY,
                by: 24
            ).forEach { y in
                context.move(to: CGPoint(x: content.minX, y: y))
                context.addLine(to: CGPoint(x: content.maxX, y: y))
            }
            context.strokePath()
        case .checklist:
            stride(
                from: content.minY + 22,
                through: content.maxY,
                by: 36
            ).forEach { y in
                context.stroke(
                    CGRect(
                        x: content.minX,
                        y: y - 11,
                        width: 14,
                        height: 14
                    )
                )
                context.move(
                    to: CGPoint(x: content.minX + 26, y: y + 4)
                )
                context.addLine(
                    to: CGPoint(x: content.maxX, y: y + 4)
                )
            }
            context.strokePath()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let pageText = "\(pageIndex + 1)"
        pageText.draw(
            in: CGRect(
                x: content.maxX - 60,
                y: bounds.maxY - 36,
                width: 60,
                height: 18
            ),
            withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(
                    ofSize: 8,
                    weight: .medium
                ),
                .foregroundColor:
                    UIColor.secondaryLabel.withAlphaComponent(0.55),
                .paragraphStyle: paragraph
            ]
        )
    }
}

struct ScanPDFRenderer: @unchecked Sendable {
    private let portraitPage = CGSize(width: 612, height: 792)
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true
    ])

    func releaseCachedResources() {
        ciContext.clearCaches()
    }

    func render(images: [UIImage], to destination: URL) throws {
        try render(
            pages: images.map(ScanPageImage.init(image:)),
            to: destination,
            options: .original
        )
    }

    func render(
        pages: [ScanPageImage],
        to destination: URL,
        enhancement: ScanEnhancement
    ) throws {
        try render(
            pages: pages,
            to: destination,
            options: ScanProcessingOptions(
                enhancement: enhancement,
                autoCrop: false,
                removeShadows: enhancement == .document,
                cleanEdges: false
            )
        )
    }

    func render(
        pages: [ScanPageImage],
        to destination: URL,
        options: ScanProcessingOptions,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        guard !pages.isEmpty else {
            throw PaperPathError.emptyScan
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "PaperPath",
            kCGPDFContextTitle as String: destination
                .deletingPathExtension()
                .lastPathComponent
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: portraitPage),
            format: format
        )
        progress(0)

        do {
            try renderer.writePDF(to: destination) { context in
                for (index, page) in pages.enumerated() {
                    if Task.isCancelled { return }
                    autoreleasepool {
                        let source = processingSized(
                            page.image,
                            longestEdge: 3_200
                        )
                        let result = processed(
                            source,
                            options:
                                page.processingOptions
                                    ?? options
                        )
                        context.beginPage()
                        UIColor.white.setFill()
                        context.cgContext.fill(
                            CGRect(origin: .zero, size: portraitPage)
                        )
                        result.image.draw(
                            in: fittedRect(for: result.image.size)
                        )
                    }
                    if Task.isCancelled { return }
                    progress(
                        Double(index + 1)
                            / Double(max(1, pages.count))
                    )
                }
            }
            try Task.checkCancellation()
            LocalFileSecurity.applyCompleteProtection(to: destination)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.storageFailure(
                "The scanned pages could not be rendered."
            )
        }
    }

    func preview(
        image: UIImage,
        enhancement: ScanEnhancement
    ) -> UIImage {
        preview(
            image: image,
            options: ScanProcessingOptions(
                enhancement: enhancement,
                autoCrop: false,
                removeShadows: enhancement == .document,
                cleanEdges: false
            )
        ).image
    }

    func preview(
        image: UIImage,
        options: ScanProcessingOptions
    ) -> ScanPreviewResult {
        processed(
            processingSized(image, longestEdge: 1_600),
            options: options
        )
    }

    private func processed(
        _ image: UIImage,
        options: ScanProcessingOptions
    ) -> ScanPreviewResult {
        guard !Task.isCancelled else {
            return ScanPreviewResult(
                image: image,
                detectedDocument: false,
                cropQuad: nil
            )
        }
        guard var input = CIImage(
            image: image,
            options: [.applyOrientationProperty: true]
        ) else {
            return ScanPreviewResult(
                image: image,
                detectedDocument: false,
                cropQuad: nil
            )
        }

        var detectedDocument = false
        var appliedCropQuad: ScanCropQuad?
        if let quad = options.manualCrop,
           quad.isValid {
            let correction = CIFilter.perspectiveCorrection()
            correction.inputImage = input
            correction.topLeft = imagePoint(
                quad.topLeft,
                extent: input.extent
            )
            correction.topRight = imagePoint(
                quad.topRight,
                extent: input.extent
            )
            correction.bottomLeft = imagePoint(
                quad.bottomLeft,
                extent: input.extent
            )
            correction.bottomRight = imagePoint(
                quad.bottomRight,
                extent: input.extent
            )
            correction.crop = true
            if let corrected = correction.outputImage,
               corrected.extent.width > 80,
               corrected.extent.height > 80 {
                input = corrected
                detectedDocument = true
                appliedCropQuad = quad
            }
        }

        if !detectedDocument,
           options.autoCrop,
           let rectangle = detectedRectangle(in: image) {
            let correction = CIFilter.perspectiveCorrection()
            correction.inputImage = input
            correction.topLeft = imagePoint(
                rectangle.topLeft,
                extent: input.extent
            )
            correction.topRight = imagePoint(
                rectangle.topRight,
                extent: input.extent
            )
            correction.bottomLeft = imagePoint(
                rectangle.bottomLeft,
                extent: input.extent
            )
            correction.bottomRight = imagePoint(
                rectangle.bottomRight,
                extent: input.extent
            )
            correction.crop = true
            if let corrected = correction.outputImage,
               corrected.extent.width > 80,
               corrected.extent.height > 80 {
                input = corrected
                detectedDocument = true
                appliedCropQuad = cropQuad(from: rectangle)
            }
        }

        if options.cleanEdges && detectedDocument {
            let inset = max(
                1,
                min(input.extent.width, input.extent.height) * 0.004
            )
            let trimmed = input.extent.insetBy(dx: inset, dy: inset)
            if trimmed.width > 80, trimmed.height > 80 {
                input = input.cropped(to: trimmed)
            }
        }

        let enhancedOutput = enhanced(
            input,
            enhancement: options.enhancement,
            removeShadows: options.removeShadows
        )
        let output = toneAdjusted(
            enhancedOutput,
            brightness: options.brightness,
            contrast: options.contrast
        ).cropped(to: input.extent)
        guard let cgImage = ciContext.createCGImage(
            output,
            from: output.extent
        ) else {
            return ScanPreviewResult(
                image: image,
                detectedDocument: detectedDocument,
                cropQuad: appliedCropQuad
            )
        }
        return ScanPreviewResult(
            image: UIImage(cgImage: cgImage),
            detectedDocument: detectedDocument,
            cropQuad: appliedCropQuad
        )
    }

    private func enhanced(
        _ input: CIImage,
        enhancement: ScanEnhancement,
        removeShadows: Bool
    ) -> CIImage {
        var working = input
        if removeShadows && enhancement != .document {
            let enhancer = CIFilter.documentEnhancer()
            enhancer.inputImage = working
            enhancer.amount = enhancement == .color ? 0.45 : 0.8
            working = enhancer.outputImage ?? working
        }

        switch enhancement {
        case .original:
            return working
        case .color:
            let shadows = CIFilter.highlightShadowAdjust()
            shadows.inputImage = working
            shadows.shadowAmount = removeShadows ? 0.4 : 0.18
            shadows.highlightAmount = 0.92
            shadows.radius = 1
            let controls = CIFilter.colorControls()
            controls.inputImage = shadows.outputImage ?? working
            controls.contrast = 1.08
            controls.saturation = 1.06
            return controls.outputImage ?? working
        case .document:
            let enhancer = CIFilter.documentEnhancer()
            enhancer.inputImage = working
            enhancer.amount = removeShadows ? 1 : 0.55
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = enhancer.outputImage ?? working
            sharpen.sharpness = 0.42
            return sharpen.outputImage ?? working
        case .grayscale:
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = working
            return mono.outputImage ?? working
        case .blackAndWhite:
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = working
            let threshold = CIFilter.colorThresholdOtsu()
            threshold.inputImage = mono.outputImage ?? working
            return threshold.outputImage ?? mono.outputImage ?? working
        }
    }

    private func toneAdjusted(
        _ input: CIImage,
        brightness: Double,
        contrast: Double
    ) -> CIImage {
        let boundedBrightness = min(0.5, max(-0.5, brightness))
        let boundedContrast = min(1.5, max(0.5, contrast))
        guard abs(boundedBrightness) > 0.001
                || abs(boundedContrast - 1) > 0.001
        else {
            return input
        }
        let controls = CIFilter.colorControls()
        controls.inputImage = input
        controls.brightness = Float(boundedBrightness)
        controls.contrast = Float(boundedContrast)
        return controls.outputImage ?? input
    }

    private func detectedRectangle(
        in image: UIImage
    ) -> VNRectangleObservation? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.62
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1
        request.minimumSize = 0.28
        request.quadratureTolerance = 22
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: image.imageOrientation.cgOrientation
        )
        do {
            guard !Task.isCancelled else {
                request.cancel()
                return nil
            }
            try handler.perform([request])
            guard !Task.isCancelled else {
                request.cancel()
                return nil
            }
            return request.results?.first
        } catch {
            return nil
        }
    }

    private func imagePoint(
        _ normalized: CGPoint,
        extent: CGRect
    ) -> CGPoint {
        CGPoint(
            x: extent.minX + normalized.x * extent.width,
            y: extent.minY + normalized.y * extent.height
        )
    }

    private func imagePoint(
        _ normalized: ScanCropPoint,
        extent: CGRect
    ) -> CGPoint {
        CGPoint(
            x: extent.minX
                + CGFloat(normalized.x) * extent.width,
            y: extent.maxY
                - CGFloat(normalized.y) * extent.height
        )
    }

    private func cropQuad(
        from rectangle: VNRectangleObservation
    ) -> ScanCropQuad? {
        let quad = ScanCropQuad(
            topLeft: ScanCropPoint(
                x: Double(rectangle.topLeft.x),
                y: Double(1 - rectangle.topLeft.y)
            ),
            topRight: ScanCropPoint(
                x: Double(rectangle.topRight.x),
                y: Double(1 - rectangle.topRight.y)
            ),
            bottomRight: ScanCropPoint(
                x: Double(rectangle.bottomRight.x),
                y: Double(1 - rectangle.bottomRight.y)
            ),
            bottomLeft: ScanCropPoint(
                x: Double(rectangle.bottomLeft.x),
                y: Double(1 - rectangle.bottomLeft.y)
            )
        )
        return quad.isValid ? quad : nil
    }

    private func fittedRect(for imageSize: CGSize) -> CGRect {
        let inset: CGFloat = 12
        let available = CGRect(
            x: inset,
            y: inset,
            width: portraitPage.width - inset * 2,
            height: portraitPage.height - inset * 2
        )
        guard imageSize.width > 0, imageSize.height > 0 else {
            return available
        }
        let scale = min(
            available.width / imageSize.width,
            available.height / imageSize.height
        )
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func processingSized(
        _ image: UIImage,
        longestEdge: CGFloat
    ) -> UIImage {
        let edge = max(image.size.width, image.size.height)
        guard edge > longestEdge else { return image }
        let scale = longestEdge / edge
        let size = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )
        return image.preparingThumbnail(of: size) ?? image
    }
}

private extension UIImage.Orientation {
    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
