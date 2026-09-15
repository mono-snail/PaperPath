import SwiftUI
import VisionKit

@MainActor
struct DocumentScannerView: UIViewControllerRepresentable {
    var maximumPageCount = 64
    let onComplete: @MainActor ([UIImage]) -> Void
    let onCancel: @MainActor () -> Void
    let onError: @MainActor (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onComplete: onComplete,
            onCancel: onCancel,
            onError: onError,
            maximumPageCount: min(max(1, maximumPageCount), 64)
        )
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: VNDocumentCameraViewController,
        context: Context
    ) {}

    static func dismantleUIViewController(
        _ uiViewController: VNDocumentCameraViewController,
        coordinator: Coordinator
    ) {
        coordinator.cancelProcessing()
    }

    @MainActor
    final class Coordinator:
        NSObject,
        @preconcurrency VNDocumentCameraViewControllerDelegate {
        private final class ImageBox: @unchecked Sendable {
            let image: UIImage

            init(_ image: UIImage) {
                self.image = image
            }
        }

        let onComplete: @MainActor ([UIImage]) -> Void
        let onCancel: @MainActor () -> Void
        let onError: @MainActor (Error) -> Void
        let maximumPageCount: Int
        private var processingTask: Task<Void, Never>?
        private var processingGeneration = UUID()
        private weak var preparationOverlay: UIView?
        private weak var preparationLabel: UILabel?
        private weak var preparationProgress: UIProgressView?

        init(
            onComplete: @escaping @MainActor ([UIImage]) -> Void,
            onCancel: @escaping @MainActor () -> Void,
            onError: @escaping @MainActor (Error) -> Void,
            maximumPageCount: Int
        ) {
            self.onComplete = onComplete
            self.onCancel = onCancel
            self.onError = onError
            self.maximumPageCount = maximumPageCount
        }

        deinit {
            processingTask?.cancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            guard scan.pageCount > 0 else {
                onError(PaperPathError.emptyScan)
                return
            }
            guard scan.pageCount <= maximumPageCount else {
                onError(
                    PaperPathError.insufficientSelection(
                        AppLocalization.format(
                            "Scan up to %lld pages at a time.",
                            maximumPageCount
                        )
                    )
                )
                return
            }
            guard processingTask == nil else { return }
            let processingLimits = Self.processingLimits(
                pageCount: scan.pageCount
            )
            let generation = UUID()
            processingGeneration = generation
            showPreparationOverlay(
                in: controller,
                pageCount: scan.pageCount
            )
            let pageCount = scan.pageCount
            processingTask = Task { @MainActor [weak self, scan] in
                guard let self else { return }
                var images: [UIImage] = []
                images.reserveCapacity(pageCount)
                for pageIndex in 0..<pageCount {
                    guard !Task.isCancelled else { return }
                    let source = ImageBox(
                        scan.imageOfPage(at: pageIndex)
                    )
                    let preparationTask = Task.detached(
                        priority: .userInitiated
                    ) {
                        ImageBox(
                            autoreleasepool {
                                Self.preparedImage(
                                    source.image,
                                    maximumPixelDimension:
                                        processingLimits.maximumDimension,
                                    maximumPixelCount:
                                        processingLimits.maximumPixelCount
                                )
                            }
                        )
                    }
                    let prepared = await withTaskCancellationHandler {
                        await preparationTask.value
                    } onCancel: {
                        preparationTask.cancel()
                    }
                    guard !Task.isCancelled,
                          self.processingGeneration == generation
                    else { return }
                    images.append(prepared.image)
                    self.updatePreparationProgress(
                        completed: pageIndex + 1,
                        total: pageCount
                    )
                }
                guard !Task.isCancelled,
                      self.processingGeneration == generation
                else { return }
                self.processingTask = nil
                self.hidePreparationOverlay()
                self.onComplete(images)
            }
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            cancelProcessing()
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            cancelProcessing()
            onError(error)
        }

        func cancelProcessing() {
            processingGeneration = UUID()
            processingTask?.cancel()
            processingTask = nil
            hidePreparationOverlay()
        }

        private func showPreparationOverlay(
            in controller: UIViewController,
            pageCount: Int
        ) {
            let effect = UIBlurEffect(style: .systemMaterial)
            let blocker = UIView()
            blocker.translatesAutoresizingMaskIntoConstraints = false
            blocker.backgroundColor = UIColor.black.withAlphaComponent(0.18)

            let overlay = UIVisualEffectView(effect: effect)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.layer.cornerRadius = 12
            overlay.clipsToBounds = true

            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 0
            label.text = AppLocalization.format(
                "Preparing %lld of %lld pages",
                0,
                pageCount
            )
            let progress = UIProgressView(progressViewStyle: .default)
            progress.progress = 0
            progress.accessibilityLabel =
                "Scan preparation progress".localizedUI
            progress.accessibilityValue = AppLocalization.format(
                "%lld of %lld processed",
                0,
                pageCount
            )
            let cancelButton = UIButton(type: .system)
            cancelButton.setTitle("Cancel".localizedUI, for: .normal)
            cancelButton.titleLabel?.font =
                .preferredFont(forTextStyle: .headline)
            cancelButton.addAction(
                UIAction { [weak self] _ in
                    guard let self else { return }
                    self.cancelProcessing()
                    self.onCancel()
                },
                for: .touchUpInside
            )
            cancelButton.heightAnchor.constraint(
                greaterThanOrEqualToConstant: 44
            ).isActive = true

            let stack = UIStackView(
                arrangedSubviews: [
                    label,
                    progress,
                    cancelButton
                ]
            )
            stack.axis = .vertical
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            overlay.contentView.addSubview(stack)
            blocker.addSubview(overlay)
            controller.view.addSubview(blocker)

            NSLayoutConstraint.activate([
                blocker.leadingAnchor.constraint(
                    equalTo: controller.view.leadingAnchor
                ),
                blocker.trailingAnchor.constraint(
                    equalTo: controller.view.trailingAnchor
                ),
                blocker.topAnchor.constraint(
                    equalTo: controller.view.topAnchor
                ),
                blocker.bottomAnchor.constraint(
                    equalTo: controller.view.bottomAnchor
                ),
                overlay.centerXAnchor.constraint(
                    equalTo: blocker.centerXAnchor
                ),
                overlay.centerYAnchor.constraint(
                    equalTo: blocker.centerYAnchor
                ),
                overlay.widthAnchor.constraint(
                    lessThanOrEqualTo: blocker.widthAnchor,
                    constant: -48
                ),
                overlay.widthAnchor.constraint(
                    greaterThanOrEqualToConstant: 220
                ),
                stack.leadingAnchor.constraint(
                    equalTo: overlay.contentView.leadingAnchor,
                    constant: 20
                ),
                stack.trailingAnchor.constraint(
                    equalTo: overlay.contentView.trailingAnchor,
                    constant: -20
                ),
                stack.topAnchor.constraint(
                    equalTo: overlay.contentView.topAnchor,
                    constant: 18
                ),
                stack.bottomAnchor.constraint(
                    equalTo: overlay.contentView.bottomAnchor,
                    constant: -18
                )
            ])
            blocker.accessibilityViewIsModal = true
            blocker.accessibilityLabel =
                "Preparing scanned pages".localizedUI
            preparationOverlay = blocker
            preparationLabel = label
            preparationProgress = progress
            UIAccessibility.post(
                notification: .screenChanged,
                argument: label
            )
        }

        private func updatePreparationProgress(
            completed: Int,
            total: Int
        ) {
            preparationLabel?.text = AppLocalization.format(
                "Preparing %lld of %lld pages",
                completed,
                total
            )
            preparationProgress?.setProgress(
                Float(completed) / Float(max(1, total)),
                animated: !UIAccessibility.isReduceMotionEnabled
            )
            preparationProgress?.accessibilityValue =
                AppLocalization.format(
                    "%lld of %lld processed",
                    completed,
                    total
                )
        }

        private func hidePreparationOverlay() {
            preparationOverlay?.removeFromSuperview()
            preparationOverlay = nil
            preparationLabel = nil
            preparationProgress = nil
        }

        private static func processingLimits(
            pageCount: Int
        ) -> (
            maximumDimension: CGFloat,
            maximumPixelCount: Double
        ) {
            let processInfo = ProcessInfo.processInfo
            let isConstrained =
                processInfo.physicalMemory
                    < 4 * 1_024 * 1_024 * 1_024
                || processInfo.isLowPowerModeEnabled
                || processInfo.thermalState == .serious
                || processInfo.thermalState == .critical
            let totalPixelBudget = isConstrained
                ? 32_000_000.0
                : 64_000_000.0
            let maximumPixelCount = max(
                500_000,
                totalPixelBudget / Double(max(1, pageCount))
            )
            let maximumDimension: CGFloat
            if pageCount > 24 {
                maximumDimension = 1_200
            } else if isConstrained || pageCount > 8 {
                maximumDimension = 1_600
            } else if pageCount > 4 {
                maximumDimension = 2_400
            } else {
                maximumDimension = 3_200
            }
            return (maximumDimension, maximumPixelCount)
        }

        nonisolated private static func preparedImage(
            _ image: UIImage,
            maximumPixelDimension: CGFloat,
            maximumPixelCount: Double
        ) -> UIImage {
            let resolvedSize = orientedPixelSize(of: image)
            let longestEdge = max(
                resolvedSize.width,
                resolvedSize.height
            )
            let pixelCount =
                Double(resolvedSize.width) * Double(resolvedSize.height)
            guard longestEdge > 0,
                  pixelCount > 0
            else { return image }
            let edgeScale = maximumPixelDimension / longestEdge
            let areaScale = CGFloat(
                sqrt(maximumPixelCount / pixelCount)
            )
            let scale = min(1, min(edgeScale, areaScale))
            guard scale < 1 else { return image }
            let targetSize = CGSize(
                width: max(1, resolvedSize.width * scale),
                height: max(1, resolvedSize.height * scale)
            )
            if let prepared = image.preparingThumbnail(of: targetSize) {
                return prepared
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(
                size: targetSize,
                format: format
            ).image { _ in
                UIColor.white.setFill()
                UIRectFill(
                    CGRect(origin: .zero, size: targetSize)
                )
                image.draw(
                    in: CGRect(origin: .zero, size: targetSize)
                )
            }
        }

        nonisolated private static func orientedPixelSize(
            of image: UIImage
        ) -> CGSize {
            let sourceSize: CGSize
            if let cgImage = image.cgImage {
                sourceSize = CGSize(
                    width: cgImage.width,
                    height: cgImage.height
                )
            } else {
                sourceSize = CGSize(
                    width: image.size.width * image.scale,
                    height: image.size.height * image.scale
                )
            }
            switch image.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                return CGSize(
                    width: sourceSize.height,
                    height: sourceSize.width
                )
            default:
                return sourceSize
            }
        }
    }
}
