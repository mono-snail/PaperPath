import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIActivityIndicatorView(style: .medium)
    private let openButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        receivePDFs()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 360, height: 320)

        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 34,
            weight: .semibold
        )
        symbolView.image = UIImage(
            systemName: "doc.badge.arrow.up",
            withConfiguration: symbolConfiguration
        )
        symbolView.tintColor = UIColor(
            red: 0.05,
            green: 0.32,
            blue: 0.57,
            alpha: 1
        )
        symbolView.contentMode = .scaleAspectFit
        symbolView.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.text = "Add to PaperPath"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.minimumScaleFactor = 0.8

        detailLabel.text = "Preparing private copies..."
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 2

        progressView.startAnimating()

        var openConfiguration = UIButton.Configuration.filled()
        openConfiguration.title = "Open PaperPath"
        openConfiguration.image = UIImage(
            systemName: "arrow.up.forward.app.fill"
        )
        openConfiguration.imagePadding = 8
        openConfiguration.cornerStyle = .medium
        openButton.configuration = openConfiguration
        openButton.isHidden = true
        openButton.addTarget(
            self,
            action: #selector(openPaperPath),
            for: .touchUpInside
        )

        var doneConfiguration = UIButton.Configuration.plain()
        doneConfiguration.title = "Done"
        doneButton.configuration = doneConfiguration
        doneButton.isHidden = true
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
                progressView,
                openButton,
                doneButton
            ]
        )
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        stack.setCustomSpacing(22, after: symbolView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            symbolView.heightAnchor.constraint(equalToConstant: 48),
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -24
            ),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func receivePDFs() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter {
                $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            } ?? []

        guard !providers.isEmpty else {
            showResult(
                importedCount: 0,
                failureCount: 1,
                fallbackMessage: "Choose one or more PDF files."
            )
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var importedCount = 0
        var failureCount = 0

        for provider in providers.prefix(20) {
            group.enter()
            provider.loadFileRepresentation(
                forTypeIdentifier: UTType.pdf.identifier
            ) { url, error in
                defer { group.leave() }
                guard error == nil, let url else {
                    lock.withLock { failureCount += 1 }
                    return
                }
                do {
                    _ = try ExternalPDFInbox.stagePDF(
                        from: url,
                        suggestedName: provider.suggestedName
                    )
                    lock.withLock { importedCount += 1 }
                } catch {
                    lock.withLock { failureCount += 1 }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.showResult(
                importedCount: importedCount,
                failureCount: failureCount,
                fallbackMessage: nil
            )
        }
    }

    private func showResult(
        importedCount: Int,
        failureCount: Int,
        fallbackMessage: String?
    ) {
        progressView.stopAnimating()
        progressView.isHidden = true
        doneButton.isHidden = false

        guard importedCount > 0 else {
            titleLabel.text = "Couldn’t Add PDF"
            detailLabel.text = fallbackMessage
                ?? "PaperPath couldn’t read the selected files."
            detailLabel.textColor = .systemRed
            openButton.isHidden = true
            return
        }

        titleLabel.text = "Ready for PaperPath"
        if failureCount > 0 {
            detailLabel.text =
                "\(importedCount) ready · \(failureCount) couldn’t be read"
        } else {
            detailLabel.text = importedCount == 1
                ? "1 private PDF copy is ready."
                : "\(importedCount) private PDF copies are ready."
        }
        detailLabel.textColor = .secondaryLabel
        openButton.isHidden = false
    }

    @objc
    private func openPaperPath() {
        guard let url = URL(string: "paperpath://import") else { return }
        openButton.isEnabled = false
        extensionContext?.open(url) { [weak self] opened in
            DispatchQueue.main.async {
                guard let self else { return }
                if opened {
                    self.extensionContext?.completeRequest(
                        returningItems: nil
                    )
                } else {
                    self.openButton.isEnabled = true
                    self.detailLabel.text =
                        "Saved. Open PaperPath to finish importing."
                }
            }
        }
    }

    @objc
    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
