import CoreGraphics
import Foundation
import PDFKit

struct PDFFormInspectionService: Sendable {
    private let maximumFormFields = 10_000
    private let maximumAnnotationsScanned = 50_000

    func fields(in url: URL) throws -> [PDFFormFieldSnapshot] {
        try inspect(url: url).fields
    }

    func inspect(url: URL) throws -> PDFFormInspectionReport {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: url),
              !document.isLocked
        else {
            throw PaperPathError.unreadablePDF
        }

        let catalog = catalogFeatures(in: url)
        var fields: [PDFFormFieldSnapshot] = []
        fields.reserveCapacity(32)
        var annotationCount = 0
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                continue
            }
            let pageBounds = page.bounds(for: .cropBox)
            guard pageBounds.width > 0, pageBounds.height > 0 else {
                continue
            }
            let annotations = page.annotations
            annotationCount += annotations.count
            guard annotationCount <= maximumAnnotationsScanned else {
                throw PaperPathError.insufficientSelection(
                    "This PDF contains too many annotations to inspect safely."
                )
            }
            var placedSignatureBounds: [CGRect] = []
            placedSignatureBounds.reserveCapacity(
                min(annotations.count, 32)
            )
            for (annotationIndex, annotation) in annotations.enumerated() {
                if annotationIndex.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                if isPlacedSignature(annotation) {
                    placedSignatureBounds.append(annotation.bounds)
                }
            }
            for (annotationIndex, annotation) in annotations.enumerated() {
                if annotationIndex.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                guard isWidget(annotation) else { continue }
                guard fields.count < maximumFormFields else {
                    throw PaperPathError.insufficientSelection(
                        "This form contains too many fields to inspect safely."
                    )
                }
                fields.append(
                    snapshot(
                        annotation,
                        annotationIndex: annotationIndex,
                        pageIndex: pageIndex,
                        pageBounds: pageBounds,
                        placedSignatureBounds: placedSignatureBounds
                    )
                )
            }
        }
        let automation = try PDFFormAutomationService().inspect(
            url: url,
            fields: fields
        )

        var issues: [String] = []
        if catalog.hasXFA {
            issues.append(
                "This PDF uses XFA. PaperPath preserves it but does not edit XFA fields."
            )
        }
        if catalog.hasJavaScript {
            issues.append(
                "Document-level JavaScript is preserved but not executed."
            )
        }
        if automation.unsupportedJavaScriptCount > 0 {
            let count = automation.unsupportedJavaScriptCount
            issues.append(
                "\(count) custom field script\(count == 1 ? "" : "s") require\(count == 1 ? "s" : "") a compatible PDF reader."
            )
        }
        let pendingCalculations = automation.fields.filter {
            $0.calculation != nil
                && $0.needsUpdate
                && $0.validationIssue == nil
        }
        if !pendingCalculations.isEmpty {
            issues.append(
                "\(pendingCalculations.count) calculated field\(pendingCalculations.count == 1 ? "" : "s") need\(pendingCalculations.count == 1 ? "s" : "") a local refresh."
            )
        }
        let invalidAutomation = automation.fields.filter {
            $0.validationIssue != nil
        }
        if !invalidAutomation.isEmpty {
            issues.append(
                "\(invalidAutomation.count) field value\(invalidAutomation.count == 1 ? "" : "s") fail\(invalidAutomation.count == 1 ? "s" : "") format or calculation validation."
            )
        }
        if catalog.needsAppearances {
            issues.append(
                "The PDF asks readers to regenerate field appearances."
            )
        }
        let duplicateTypeConflicts = Dictionary(
            grouping: fields,
            by: { $0.name.lowercased() }
        ).filter { _, values in
            Set(values.map(\.kind)).count > 1
        }
        if !duplicateTypeConflicts.isEmpty {
            issues.append(
                "\(duplicateTypeConflicts.count) field name conflict\(duplicateTypeConflicts.count == 1 ? "" : "s") use different field types."
            )
        }
        let fieldIssues = fields.compactMap(\.issue)
        if !fieldIssues.isEmpty {
            issues.append(
                "\(fieldIssues.count) field\(fieldIssues.count == 1 ? "" : "s") need\(fieldIssues.count == 1 ? "s" : "") compatibility review."
            )
        }

        let compatibility: PDFFormCompatibility
        if catalog.hasXFA {
            compatibility = .unsupported
        } else if !issues.isEmpty {
            compatibility = .limited
        } else {
            compatibility = .ready
        }
        return PDFFormInspectionReport(
            fields: fields,
            automationFields: automation.fields,
            compatibility: compatibility,
            issues: issues,
            hasXFA: catalog.hasXFA,
            hasJavaScript: catalog.hasJavaScript
                || automation.encounteredJavaScriptCount > 0,
            needsAppearances: catalog.needsAppearances,
            unsupportedJavaScriptCount:
                automation.unsupportedJavaScriptCount
                    + (catalog.hasJavaScript ? 1 : 0)
        )
    }

    private func snapshot(
        _ annotation: PDFAnnotation,
        annotationIndex: Int,
        pageIndex: Int,
        pageBounds: CGRect,
        placedSignatureBounds: [CGRect]
    ) -> PDFFormFieldSnapshot {
        let flags = (
            annotation.value(
                forAnnotationKey: .widgetFieldFlags
            ) as? NSNumber
        )?.intValue ?? 0
        let kind = fieldKind(annotation)
        let bounds = annotation.bounds.intersection(pageBounds)
        let normalizedBounds = bounds.isNull
            ? PDFNormalizedRect(x: 0, y: 0, width: 0, height: 0)
            : PDFNormalizedRect(
                x: (bounds.minX - pageBounds.minX) / pageBounds.width,
                y: (pageBounds.maxY - bounds.maxY) / pageBounds.height,
                width: bounds.width / pageBounds.width,
                height: bounds.height / pageBounds.height
            )
        let storedName = annotation.fieldName
            ?? annotation.value(
                forAnnotationKey: .textLabel
            ) as? String
        let name = storedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fieldName = name?.isEmpty == false
            ? name!
            : "Unnamed field \(annotationIndex + 1)"
        let value: String?
        switch kind {
        case .checkbox, .radio, .button:
            value = annotation.widgetStringValue
                ?? annotation.buttonWidgetStateString
        case .signature:
            let rawValue = annotation.value(
                forAnnotationKey: .widgetValue
            )
            if let text = rawValue as? String {
                value = text
            } else if let dictionary = rawValue as? NSDictionary,
                      dictionary.count > 0 {
                value = "Signed"
            } else if hasPlacedSignature(
                in: bounds,
                placedSignatureBounds: placedSignatureBounds
            ) {
                value = "Signed"
            } else {
                value = nil
            }
        default:
            value = annotation.widgetStringValue
        }
        let issue = fieldIssue(
            annotation,
            kind: kind,
            bounds: bounds,
            pageBounds: pageBounds,
            name: name
        )
        return PDFFormFieldSnapshot(
            id: "\(pageIndex)-\(annotationIndex)-\(fieldName)",
            pageIndex: pageIndex,
            annotationIndex: annotationIndex,
            name: fieldName,
            kind: kind,
            value: value,
            normalizedBounds: normalizedBounds,
            isRequired: flags & 2 != 0,
            isReadOnly: annotation.isReadOnly || flags & 1 != 0,
            isMultiline: annotation.isMultiline,
            maximumLength: annotation.maximumLength > 0
                ? annotation.maximumLength
                : nil,
            optionCount: annotation.choices?.count ?? 0,
            hasAppearanceStream: annotation.hasAppearanceStream,
            issue: issue
        )
    }

    private func fieldKind(
        _ annotation: PDFAnnotation
    ) -> PDFFormFieldKind {
        switch annotation.widgetFieldType {
        case .text:
            return .text
        case .choice:
            return .choice
        case .signature:
            return .signature
        case .button:
            switch annotation.widgetControlType {
            case .checkBoxControl:
                return .checkbox
            case .radioButtonControl:
                return .radio
            case .pushButtonControl:
                return .button
            default:
                return .unknown
            }
        default:
            return .unknown
        }
    }

    private func fieldIssue(
        _ annotation: PDFAnnotation,
        kind: PDFFormFieldKind,
        bounds: CGRect,
        pageBounds: CGRect,
        name: String?
    ) -> String? {
        if name?.isEmpty != false {
            return "This field has no stable name."
        }
        if bounds.isNull
            || bounds.width < 4
            || bounds.height < 4
            || !pageBounds.intersects(bounds) {
            return "This field has invalid page bounds."
        }
        if annotation.isPasswordField {
            return "Password fields are preserved but not inspected."
        }
        if kind == .choice,
           let values = annotation.values,
           let choices = annotation.choices,
           values.count != choices.count {
            return "Choice labels and export values do not match."
        }
        if kind == .unknown {
            return "This widget type is not supported."
        }
        return nil
    }

    private func isWidget(_ annotation: PDFAnnotation) -> Bool {
        let normalizedType = annotation.type?
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            .lowercased()
        let widgetType = PDFAnnotationSubtype.widget.rawValue
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            .lowercased()
        if normalizedType == widgetType {
            return true
        }
        switch annotation.widgetFieldType {
        case .button, .choice, .signature, .text:
            return true
        default:
            return false
        }
    }

    private func isPlacedSignature(
        _ annotation: PDFAnnotation
    ) -> Bool {
        let normalizedType = annotation.type?
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            .lowercased()
        let inkType = PDFAnnotationSubtype.ink.rawValue
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            .lowercased()
        return normalizedType
            == inkType
            && annotation.contents == "Signature"
    }

    private func hasPlacedSignature(
        in fieldBounds: CGRect,
        placedSignatureBounds: [CGRect]
    ) -> Bool {
        guard fieldBounds.width > 0, fieldBounds.height > 0 else {
            return false
        }
        return placedSignatureBounds.contains { signatureBounds in
            let intersection = fieldBounds.intersection(signatureBounds)
            guard !intersection.isNull,
                  intersection.width > 0,
                  intersection.height > 0
            else { return false }
            let intersectionArea = intersection.width * intersection.height
            let smallerArea = min(
                fieldBounds.width * fieldBounds.height,
                signatureBounds.width * signatureBounds.height
            )
            return smallerArea > 0
                && intersectionArea / smallerArea >= 0.45
        }
    }

    private func catalogFeatures(
        in url: URL
    ) -> (
        hasXFA: Bool,
        hasJavaScript: Bool,
        needsAppearances: Bool
    ) {
        guard let document = CGPDFDocument(url as CFURL),
              let catalog = document.catalog
        else { return (false, false, false) }
        var acroForm: CGPDFDictionaryRef?
        var names: CGPDFDictionaryRef?
        let hasAcroForm = CGPDFDictionaryGetDictionary(
            catalog,
            "AcroForm",
            &acroForm
        )
        var xfaObject: CGPDFObjectRef?
        let hasXFA = if hasAcroForm, let acroForm {
            CGPDFDictionaryGetObject(
                acroForm,
                "XFA",
                &xfaObject
            )
        } else {
            false
        }
        var needsAppearances = false
        if let acroForm {
            _ = CGPDFDictionaryGetBoolean(
                acroForm,
                "NeedAppearances",
                &needsAppearances
            )
        }
        var javaScriptObject: CGPDFObjectRef?
        let hasNames = CGPDFDictionaryGetDictionary(
            catalog,
            "Names",
            &names
        )
        let hasJavaScript = if hasNames, let names {
            CGPDFDictionaryGetObject(
                names,
                "JavaScript",
                &javaScriptObject
            )
        } else {
            false
        }
        return (hasXFA, hasJavaScript, needsAppearances)
    }
}
