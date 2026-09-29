import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private struct ActiveLoad {
        let provider: NSItemProvider
        let progress: Progress
        let cancellationSignal: ExternalPDFInboxCancellationSignal
    }

    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIActivityIndicatorView(style: .medium)
    private let itemProgressView = UIProgressView(
        progressViewStyle: .default
    )
    private let retryButton = UIButton(type: .system)
    private let openButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let maximumItemCount = 20
    private let maximumConcurrentLoads = 2

    private var intakeGeneration = UUID()
    private var providers: [NSItemProvider] = []
    private var nextProviderIndex = 0
    private var completedProviderCount = 0
    private var importedCount = 0
    private var failureCount = 0
    private var skippedCount = 0
    private var firstFailureMessage: String?
    private var activeLoads: [UUID: ActiveLoad] = [:]
    private var copyProgressByLoadID: [UUID: Float] = [:]
    private var stagedItems: [ExternalPDFInboxItem] = []
    private var failedProviders: [NSItemProvider] = []
    private var isReceiving = false
    private var didFinishStaging = false
    private var isOpeningPaperPath = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        observeProtectedLifecycle()
        receivePDFs()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isReceiving && !didFinishStaging {
            cancelReception()
        }
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        view.tintColor = brandColor
        preferredContentSize = CGSize(width: 360, height: 380)

        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 34,
            weight: .semibold
        )
        symbolView.image = UIImage(
            systemName: "doc.badge.arrow.up",
            withConfiguration: symbolConfiguration
        )
        symbolView.preferredSymbolConfiguration = symbolConfiguration
        symbolView.tintColor = brandColor
        symbolView.contentMode = .scaleAspectFit
        symbolView.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.text = localized("Add to PaperPath")
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        detailLabel.text = localized("Preparing private copies...")
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        progressView.startAnimating()
        itemProgressView.progress = 0
        itemProgressView.progressTintColor = symbolView.tintColor
        itemProgressView.accessibilityLabel = localized(
            "PDF import progress"
        )
        let progressRow = UIStackView(
            arrangedSubviews: [progressView, itemProgressView]
        )
        progressRow.axis = .horizontal
        progressRow.alignment = .center
        progressRow.spacing = 10

        var openConfiguration = UIButton.Configuration.filled()
        openConfiguration.title = localized("Open PaperPath")
        openConfiguration.image = UIImage(
            systemName: "arrow.up.forward.app.fill"
        )
        openConfiguration.imagePadding = 8
        openConfiguration.cornerStyle = .medium
        openConfiguration.titleLineBreakMode = .byWordWrapping
        openButton.configuration = openConfiguration
        openButton.isHidden = true
        openButton.addTarget(
            self,
            action: #selector(openPaperPath),
            for: .touchUpInside
        )
        openButton.accessibilityHint = localized(
            "Opens PaperPath to finish importing these private copies."
        )

        var retryConfiguration = UIButton.Configuration.tinted()
        retryConfiguration.title = localized("Retry Failed PDFs")
        retryConfiguration.image = UIImage(
            systemName: "arrow.clockwise"
        )
        retryConfiguration.imagePadding = 8
        retryConfiguration.cornerStyle = .medium
        retryConfiguration.titleLineBreakMode = .byWordWrapping
        retryButton.configuration = retryConfiguration
        retryButton.isHidden = true
        retryButton.addTarget(
            self,
            action: #selector(retryReception),
            for: .touchUpInside
        )
        retryButton.accessibilityHint = localized(
            "Retries only PDFs that failed. Ready copies are not duplicated."
        )

        var doneConfiguration = UIButton.Configuration.plain()
        doneConfiguration.title = localized("Cancel")
        doneConfiguration.titleLineBreakMode = .byWordWrapping
        doneButton.configuration = doneConfiguration
        doneButton.accessibilityHint = localized(
            "Stops copying and removes staged private copies."
        )
        doneButton.addTarget(
            self,
            action: #selector(finish),
            for: .touchUpInside
        )

        let stack = UIStackView(
            arrangedSubviews: [
                symbolView,
                titleLabel,
                detailLabel,
                progressRow,
                retryButton,
                openButton,
                doneButton
            ]
        )
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        stack.setCustomSpacing(22, after: symbolView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            symbolView.heightAnchor.constraint(equalToConstant: 48),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            scrollView.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor
            ),
            scrollView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor
            ),
            scrollView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor
            ),
            stack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -24
            ),
            stack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 24
            ),
            stack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -24
            ),
            stack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -48
            )
        ])
    }

    private func receivePDFs() {
        let availableProviders = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter {
                $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            } ?? []

        guard !availableProviders.isEmpty else {
            failedProviders.removeAll(keepingCapacity: false)
            showResult(
                importedCount: 0,
                failureCount: 1,
                skippedCount: 0,
                fallbackMessage: localized(
                    "Choose one or more PDF files."
                )
            )
            return
        }
        beginReception(
            with: Array(availableProviders.prefix(maximumItemCount)),
            skippedCount: max(
                0,
                availableProviders.count - maximumItemCount
            ),
            preservesImportedCount: false
        )
    }

    private func beginReception(
        with providersToLoad: [NSItemProvider],
        skippedCount: Int,
        preservesImportedCount: Bool
    ) {
        guard !providersToLoad.isEmpty else { return }
        let generation = UUID()
        intakeGeneration = generation
        isOpeningPaperPath = false
        retryButton.isHidden = true
        openButton.isHidden = true
        openButton.isEnabled = true
        doneButton.isEnabled = true
        updateDoneButtonTitle(localized("Cancel"))
        doneButton.accessibilityHint = localized(
            preservesImportedCount
                ? "Stops retrying. Previously prepared private copies stay ready."
                : "Stops copying and removes staged private copies."
        )
        progressView.isHidden = false
        progressView.startAnimating()
        itemProgressView.isHidden = false
        itemProgressView.setProgress(0, animated: false)
        detailLabel.textColor = .secondaryLabel
        providers = providersToLoad
        self.skippedCount = skippedCount
        nextProviderIndex = 0
        completedProviderCount = 0
        if !preservesImportedCount {
            importedCount = 0
        }
        failureCount = 0
        firstFailureMessage = nil
        activeLoads.removeAll(keepingCapacity: true)
        copyProgressByLoadID.removeAll(keepingCapacity: true)
        stagedItems.removeAll(keepingCapacity: true)
        failedProviders.removeAll(keepingCapacity: true)
        didFinishStaging = false
        isReceiving = true
        updateProgress()
        startAvailableLoads(generation: generation)
    }

    private func observeProtectedLifecycle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(protectedLifecycleInterrupted),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(protectedLifecycleInterrupted),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil
        )
    }

    @objc
    private func protectedLifecycleInterrupted() {
        guard isReceiving else { return }
        cancelReception()
        extensionContext?.cancelRequest(
            withError: CocoaError(.userCancelled)
        )
    }

    private func startAvailableLoads(generation: UUID) {
        guard intakeGeneration == generation, isReceiving else { return }
        while activeLoads.count < maximumConcurrentLoads,
              nextProviderIndex < providers.count {
            let provider = providers[nextProviderIndex]
            nextProviderIndex += 1
            let loadID = UUID()
            let suggestedName = provider.suggestedName
            let cancellationSignal =
                ExternalPDFInboxCancellationSignal()
            let progress = provider.loadFileRepresentation(
                forTypeIdentifier: UTType.pdf.identifier
            ) { [weak self] url, error in
                let result: Result<ExternalPDFInboxItem, Error>
                if let error {
                    result = .failure(error)
                } else if let url {
                    do {
                        result = .success(
                            try ExternalPDFInbox.stagePDF(
                                from: url,
                                suggestedName: suggestedName,
                                progress: {
                                    [weak self] processedBytes,
                                    totalBytes in
                                    Task { @MainActor [weak self] in
                                        self?.updateCopyProgress(
                                            id: loadID,
                                            generation: generation,
                                            processedBytes:
                                                processedBytes,
                                            totalBytes: totalBytes
                                        )
                                    }
                                },
                                cancellationCheck: {
                                    try cancellationSignal
                                        .checkCancellation()
                                }
                            )
                        )
                    } catch {
                        result = .failure(error)
                    }
                } else {
                    result = .failure(ExternalPDFInboxError.invalidPDF)
                }
                Task { @MainActor [weak self] in
                    self?.finishLoad(
                        id: loadID,
                        generation: generation,
                        result: result
                    )
                }
            }
            activeLoads[loadID] = ActiveLoad(
                provider: provider,
                progress: progress,
                cancellationSignal: cancellationSignal
            )
        }
    }

    private func finishLoad(
        id: UUID,
        generation: UUID,
        result: Result<ExternalPDFInboxItem, Error>
    ) {
        guard intakeGeneration == generation, isReceiving else {
            if case .success(let item) = result {
                try? ExternalPDFInbox.remove(item)
            }
            return
        }

        let activeLoad = activeLoads.removeValue(forKey: id)
        copyProgressByLoadID[id] = nil
        completedProviderCount += 1
        switch result {
        case .success(let item):
            stagedItems.append(item)
            importedCount += 1
        case .failure(let error):
            failureCount += 1
            if let provider = activeLoad?.provider {
                failedProviders.append(provider)
            }
            if firstFailureMessage == nil {
                firstFailureMessage = userFacingMessage(for: error)
            }
        }
        updateProgress()

        if completedProviderCount == providers.count {
            showResult(
                importedCount: importedCount,
                failureCount: failureCount,
                skippedCount: skippedCount,
                fallbackMessage: firstFailureMessage
            )
        } else {
            startAvailableLoads(generation: generation)
        }
    }

    private func updateProgress() {
        let total = providers.count
        let activeCopyFraction = copyProgressByLoadID.values
            .reduce(0, +)
        let fraction = total > 0
            ? min(
                1,
                (
                    Float(completedProviderCount)
                        + activeCopyFraction
                ) / Float(total)
            )
            : 0
        itemProgressView.setProgress(
            fraction,
            animated: !UIAccessibility.isReduceMotionEnabled
        )
        var detail = localizedFormat(
            "%lld of %lld processed · %lld%% prepared",
            Int64(completedProviderCount),
            Int64(total),
            Int64((fraction * 100).rounded())
        )
        itemProgressView.accessibilityValue = detail
        if skippedCount > 0 {
            detail += " · " + localizedFormat(
                "%lld over the %lld-file limit",
                Int64(skippedCount),
                Int64(maximumItemCount)
            )
        }
        detailLabel.text = detail
    }

    private func updateCopyProgress(
        id: UUID,
        generation: UUID,
        processedBytes: Int64,
        totalBytes: Int64
    ) {
        guard intakeGeneration == generation,
              isReceiving,
              activeLoads[id] != nil,
              totalBytes > 0
        else { return }
        let fraction = Float(
            min(
                1,
                max(
                    0,
                    Double(processedBytes) / Double(totalBytes)
                )
            )
        )
        guard fraction >= (copyProgressByLoadID[id] ?? 0)
        else { return }
        copyProgressByLoadID[id] = fraction
        updateProgress()
    }

    private func userFacingMessage(for error: Error) -> String? {
        if let inboxError = error as? ExternalPDFInboxError {
            return inboxError.errorDescription
        }
        if case .insufficientStorage = ExternalPDFInbox.retryReason(for: error) {
            return ExternalPDFInboxError.insufficientStorage.errorDescription
        }
        return nil
    }

    private func showResult(
        importedCount: Int,
        failureCount: Int,
        skippedCount: Int,
        fallbackMessage: String?
    ) {
        isReceiving = false
        didFinishStaging = true
        activeLoads.removeAll(keepingCapacity: true)
        copyProgressByLoadID.removeAll(keepingCapacity: true)
        providers.removeAll(keepingCapacity: false)
        stagedItems.removeAll(keepingCapacity: false)
        progressView.stopAnimating()
        progressView.isHidden = true
        itemProgressView.isHidden = true
        updateDoneButtonTitle(localized("Done"))
        doneButton.accessibilityHint = localized(
            "Closes this share sheet."
        )

        guard importedCount > 0 else {
            symbolView.image = UIImage(
                systemName: "exclamationmark.triangle.fill"
            )
            symbolView.tintColor = .systemRed
            titleLabel.text = localized("Couldn’t Add PDF")
            var detail = fallbackMessage
                ?? localized(
                    "PaperPath couldn’t read the selected files."
                )
            if skippedCount > 0 {
                detail += " " + localizedFormat(
                    "%lld more exceeded the %lld-file limit.",
                    Int64(skippedCount),
                    Int64(maximumItemCount)
                )
            }
            detailLabel.text = detail
            detailLabel.textColor = .systemRed
            openButton.isHidden = true
            configureRetryButton()
            UIAccessibility.post(
                notification: .announcement,
                argument: "\(titleLabel.text ?? ""). \(detail)"
            )
            return
        }

        symbolView.image = UIImage(systemName: "checkmark.shield.fill")
        configureRetryButton()
        symbolView.tintColor = failureCount > 0 || skippedCount > 0
            ? .systemOrange
            : .systemGreen
        titleLabel.text = localized("Ready for PaperPath")
        if failureCount > 0 || skippedCount > 0 {
            var parts = [
                localizedFormat(
                    "%lld ready",
                    Int64(importedCount)
                )
            ]
            if failureCount > 0 {
                parts.append(
                    localizedFormat(
                        "%lld couldn’t be copied",
                        Int64(failureCount)
                    )
                )
            }
            if skippedCount > 0 {
                parts.append(
                    localizedFormat(
                        "%lld skipped by the %lld-file limit",
                        Int64(skippedCount),
                        Int64(maximumItemCount)
                    )
                )
            }
            var detail = parts.joined(separator: " · ")
            if let fallbackMessage, failureCount > 0 {
                detail += "\n" + fallbackMessage
            }
            detailLabel.text = detail
        } else {
            detailLabel.text = importedCount == 1
                ? localized("1 private PDF copy is ready.")
                : localizedFormat(
                    "%lld private PDF copies are ready.",
                    Int64(importedCount)
                )
        }
        detailLabel.textColor = .secondaryLabel
        openButton.isHidden = false
        UIAccessibility.post(
            notification: .announcement,
            argument: [
                titleLabel.text,
                detailLabel.text
            ]
            .compactMap { $0 }
            .joined(separator: ". ")
        )
    }

    @objc
    private func openPaperPath() {
        guard !isOpeningPaperPath,
              let url = URL(string: "paperpath://import")
        else { return }
        setOpeningPaperPath(true)
        extensionContext?.open(url) { [weak self] opened in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if opened {
                    self.extensionContext?.completeRequest(
                        returningItems: nil
                    )
                } else {
                    self.setOpeningPaperPath(false)
                    let message = self.localized(
                        "Saved. Open PaperPath to finish importing."
                    )
                    self.detailLabel.text = message
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: message
                    )
                }
            }
        }
    }

    @objc
    private func retryReception() {
        guard !isReceiving,
              !isOpeningPaperPath,
              !failedProviders.isEmpty
        else { return }
        let retryProviders = failedProviders
        titleLabel.text = localized("Add to PaperPath")
        detailLabel.text = localized("Retrying failed PDFs...")
        symbolView.image = UIImage(systemName: "doc.badge.arrow.up")
        symbolView.tintColor = brandColor
        beginReception(
            with: retryProviders,
            skippedCount: skippedCount,
            preservesImportedCount: true
        )
        UIAccessibility.post(
            notification: .announcement,
            argument: localized("Retrying failed PDFs...")
        )
    }

    @objc
    private func finish() {
        guard !isOpeningPaperPath else { return }
        if isReceiving {
            cancelReception()
            extensionContext?.cancelRequest(
                withError: CocoaError(.userCancelled)
            )
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func cancelReception() {
        guard isReceiving else { return }
        isReceiving = false
        intakeGeneration = UUID()
        for load in activeLoads.values {
            load.cancellationSignal.cancel()
            load.progress.cancel()
        }
        activeLoads.removeAll(keepingCapacity: true)
        copyProgressByLoadID.removeAll(keepingCapacity: true)
        providers.removeAll(keepingCapacity: false)
        failedProviders.removeAll(keepingCapacity: false)
        let items = stagedItems
        stagedItems.removeAll(keepingCapacity: true)
        for item in items {
            try? ExternalPDFInbox.remove(item)
        }
    }

    private func configureRetryButton() {
        let failedCount = failedProviders.count
        retryButton.isHidden = failedCount == 0
        guard failedCount > 0 else { return }
        var configuration = retryButton.configuration
        configuration?.title = failedCount == 1
            ? localized("Retry Failed PDF")
            : localizedFormat(
                "Retry %lld Failed PDFs",
                Int64(failedCount)
            )
        retryButton.configuration = configuration
        retryButton.accessibilityHint = localized(
            "Retries only PDFs that failed. Ready copies are not duplicated."
        )
    }

    private func updateDoneButtonTitle(_ title: String) {
        var configuration = doneButton.configuration
        configuration?.title = title
        doneButton.configuration = configuration
    }

    private func setOpeningPaperPath(_ isOpening: Bool) {
        isOpeningPaperPath = isOpening
        var configuration = openButton.configuration
        configuration?.showsActivityIndicator = isOpening
        configuration?.image = isOpening
            ? nil
            : UIImage(systemName: "arrow.up.forward.app.fill")
        configuration?.title = localized(
            isOpening ? "Opening PaperPath..." : "Open PaperPath"
        )
        openButton.configuration = configuration
        openButton.isEnabled = !isOpening
        retryButton.isEnabled = !isOpening
        doneButton.isEnabled = !isOpening
        openButton.accessibilityHint = localized(
            isOpening
                ? "Wait for PaperPath to open."
                : "Opens PaperPath to finish importing these private copies."
        )
        if isOpening {
            UIAccessibility.post(
                notification: .announcement,
                argument: localized("Opening PaperPath...")
            )
        }
    }

    private func localized(_ key: String) -> String {
        ExternalPDFInbox.localized(key)
    }

    private func localizedFormat(
        _ key: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: localized(key),
            locale: ExternalPDFInbox.localizationLocale,
            arguments: arguments
        )
    }

    private var brandColor: UIColor {
        UIColor(
            named: "AccentColor",
            in: .main,
            compatibleWith: traitCollection
        ) ?? UIColor(
            red: 0.05,
            green: 0.32,
            blue: 0.57,
            alpha: 1
        )
    }
}
