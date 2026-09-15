import Foundation
import PDFKit
import UIKit

enum DemoPDFBuilder {
    static func create(at url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            drawTitle("Project handoff", in: page)
            drawParagraph(
                """
                Review the final scope, confirm the delivery date, and sign the
                acceptance section before sharing this document.
                """,
                y: 156,
                in: page
            )
            drawMetric("12", label: "pages reviewed", x: 56, y: 276)
            drawMetric("3", label: "open decisions", x: 224, y: 276)
            drawMetric("1", label: "signature needed", x: 392, y: 276)
            drawParagraph(
                """
                PaperPath inspected this working copy locally. The original
                import remains unchanged outside the app.
                """,
                y: 390,
                in: page
            )

            context.beginPage()
            drawTitle("Decision record", in: page)
            drawParagraph(
                """
                1. Keep processing on device.
                2. Export an explicit copy.
                3. Make every recommendation explainable.
                """,
                y: 156,
                in: page
            )
        }
        try addDemoFormFields(to: url)
    }

    static func createInvoice(at url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            drawTitle("Invoice #PP-2048", in: page)
            drawParagraph(
                """
                Bill to: Northstar Studio
                Invoice date: August 8, 2026
                Amount due: USD 1,280.00
                Payment terms: review within 14 days.
                Contact: billing@example.com
                """,
                y: 156,
                in: page
            )
        }
    }

    static func createReport(at url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            drawTitle("Site review report", in: page)
            drawParagraph(
                """
                Executive summary

                Findings were recorded locally. Review the final observations
                and share the approved report with the project team.
                """,
                y: 156,
                in: page
            )
        }
    }

#if DEBUG
    static func createOfficeSoak(at url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let visual = UIGraphicsImageRenderer(
            size: CGSize(width: 960, height: 540)
        ).image { context in
            UIColor(
                red: 30 / 255,
                green: 48 / 255,
                blue: 70 / 255,
                alpha: 1
            ).setFill()
            context.fill(
                CGRect(x: 0, y: 0, width: 960, height: 540)
            )
            UIColor(
                red: 44 / 255,
                green: 193 / 255,
                blue: 180 / 255,
                alpha: 1
            ).setFill()
            context.fill(
                CGRect(x: 80, y: 90, width: 800, height: 82)
            )
            UIColor.white.setFill()
            context.fill(
                CGRect(x: 80, y: 222, width: 560, height: 34)
            )
            context.fill(
                CGRect(x: 80, y: 292, width: 710, height: 34)
            )
            context.fill(
                CGRect(x: 80, y: 362, width: 430, height: 34)
            )
        }
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { context in
            for pageIndex in 0..<192 {
                autoreleasepool {
                    context.beginPage()
                    drawTitle(
                        "Office stress \(pageIndex + 1)",
                        in: page
                    )
                    drawParagraph(
                        """
                        Section \(pageIndex + 1)
                        Owner: PaperPath stability automation
                        Status: generated locally
                        Amount: \(1_000 + pageIndex * 37)
                        Notes: cancellation and memory recovery must remain bounded.
                        """,
                        y: 142,
                        in: page
                    )
                    visual.draw(
                        in: CGRect(
                            x: 56,
                            y: 350,
                            width: 500,
                            height: 281
                        )
                    )
                }
            }
        }
    }
#endif

    private static func drawTitle(_ title: String, in page: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 34, weight: .bold),
            .foregroundColor: UIColor(
                red: 24 / 255,
                green: 35 / 255,
                blue: 47 / 255,
                alpha: 1
            )
        ]
        title.draw(
            in: CGRect(x: 56, y: 70, width: page.width - 112, height: 50),
            withAttributes: attributes
        )
    }

    private static func drawParagraph(
        _ text: String,
        y: CGFloat,
        in page: CGRect
    ) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17, weight: .regular),
            .foregroundColor: UIColor(
                red: 62 / 255,
                green: 72 / 255,
                blue: 82 / 255,
                alpha: 1
            ),
            .paragraphStyle: style
        ]
        text.draw(
            in: CGRect(x: 56, y: y, width: page.width - 112, height: 150),
            withAttributes: attributes
        )
    }

    private static func drawMetric(
        _ value: String,
        label: String,
        x: CGFloat,
        y: CGFloat
    ) {
        value.draw(
            at: CGPoint(x: x, y: y),
            withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: UIColor.systemBlue
            ]
        )
        label.draw(
            in: CGRect(x: x, y: y + 42, width: 150, height: 40),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }

    private static func addDemoFormFields(to url: URL) throws {
        guard let document = PDFDocument(url: url),
              let firstPage = document.page(at: 0),
              let secondPage = document.page(at: 1)
        else {
            throw PaperPathError.unreadablePDF
        }
        let name = PDFAnnotation(
            bounds: CGRect(x: 56, y: 228, width: 260, height: 36),
            forType: .widget,
            withProperties: nil
        )
        name.widgetFieldType = .text
        name.fieldName = "Recipient name"
        name.widgetStringValue = ""
        name.font = UIFont(name: "Helvetica", size: 12)
        _ = name.setValue(
            NSNumber(value: 2),
            forAnnotationKey: .widgetFieldFlags
        )
        firstPage.addAnnotation(name)

        let signature = PDFAnnotation(
            bounds: CGRect(x: 300, y: 92, width: 220, height: 54),
            forType: .widget,
            withProperties: nil
        )
        signature.widgetFieldType = .signature
        signature.fieldName = "Approval signature"
        _ = signature.setValue(
            NSNumber(value: 2),
            forAnnotationKey: .widgetFieldFlags
        )
        secondPage.addAnnotation(signature)

        let link = PDFAnnotation(
            bounds: CGRect(x: 56, y: 548, width: 250, height: 34),
            forType: .link,
            withProperties: nil
        )
        link.contents = "PaperPath project site"
        link.url = URL(string: "https://example.com/paperpath")
        secondPage.addAnnotation(link)

        guard document.write(to: url) else {
            throw PaperPathError.storageFailure(
                "The demo form could not be written."
            )
        }
    }
}
