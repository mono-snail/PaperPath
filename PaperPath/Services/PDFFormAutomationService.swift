import Foundation
import PDFKit

struct PDFFormAutomationInspection: Sendable {
    let fields: [PDFFormAutomationFieldSnapshot]
    let encounteredJavaScriptCount: Int
    let unsupportedJavaScriptCount: Int
}

struct PDFFormAutomationService: Sendable {
    private let maximumAutomationWidgets = 20_000
    private let maximumAutomationPages = 20_000
    private let maximumAnnotationsPerPage = 4_096
    private let maximumScriptBytes = 256 * 1_024
    private let maximumScriptCharacters = 128 * 1_024
    private let maximumCalculationDepth = 128

    private struct RawAutomation {
        let fieldName: String
        let calculation: PDFFormCalculationRule?
        let format: PDFFormFormatRule?
        let rangeValidation: PDFFormRangeValidationRule?
        let encounteredActionCount: Int
        let unsupportedActionCount: Int
    }

    private struct ScriptCall {
        let name: String
        let arguments: [String]
    }

    private enum JavaScriptPayload {
        case source(String)
        case unsupported

        var sourceForInspection: String {
            switch self {
            case .source(let value): return value
            case .unsupported: return ""
            }
        }
    }

    private struct EvaluationFailure: Error {
        let message: String
    }

    func inspect(
        url: URL,
        fields: [PDFFormFieldSnapshot]
    ) throws -> PDFFormAutomationInspection {
        try Task.checkCancellation()
        guard let document = CGPDFDocument(url as CFURL),
              document.numberOfPages > 0
        else {
            return PDFFormAutomationInspection(
                fields: [],
                encounteredJavaScriptCount: 0,
                unsupportedJavaScriptCount: 0
            )
        }
        guard document.numberOfPages <= maximumAutomationPages else {
            throw PaperPathError.insufficientSelection(
                "This form contains too many pages to inspect scripted fields safely."
            )
        }
        let rawFields = try rawAutomations(in: document)
        let fieldsByName = Dictionary(
            grouping: fields,
            by: { normalizedName($0.name) }
        )
        var numericCache: [String: Result<Double, EvaluationFailure>] = [:]

        func numericValue(
            for name: String,
            stack: inout Set<String>
        ) throws -> Result<Double, EvaluationFailure> {
            try Task.checkCancellation()
            let key = normalizedName(name)
            if let cached = numericCache[key] {
                return cached
            }
            guard stack.count < maximumCalculationDepth else {
                return .failure(
                    EvaluationFailure(
                        message: AppLocalization.format(
                            "Calculation dependency for “%@” is too deep to evaluate safely.",
                            name
                        )
                    )
                )
            }
            guard !stack.contains(key) else {
                return .failure(
                    EvaluationFailure(
                        message: AppLocalization.format(
                            "Calculation cycle includes “%@”.",
                            name
                        )
                    )
                )
            }
            guard let matchingFields = fieldsByName[key],
                  let sourceField = matchingFields.first
            else {
                return .failure(
                    EvaluationFailure(
                        message: AppLocalization.format(
                            "Calculation source “%@” is missing.",
                            name
                        )
                    )
                )
            }
            guard matchingFields.count == 1 else {
                return .failure(
                    EvaluationFailure(
                        message: AppLocalization.format(
                            "Calculation source “%@” is ambiguous because the field name is repeated.",
                            name
                        )
                    )
                )
            }
            if let calculation = rawFields[key]?.calculation {
                stack.insert(key)
                let sourceValues = try calculation.sourceFieldNames.map {
                    try numericValue(for: $0, stack: &stack)
                }
                stack.remove(key)
                let failures = sourceValues.compactMap {
                    if case .failure(let failure) = $0 {
                        return failure
                    }
                    return nil
                }
                if let failure = failures.first {
                    numericCache[key] = .failure(failure)
                    return .failure(failure)
                }
                let values = sourceValues.compactMap {
                    try? $0.get()
                }
                guard !values.isEmpty else {
                    let failure = EvaluationFailure(
                        message: AppLocalization.format(
                            "Calculation “%@” has no numeric source values.",
                            sourceField.name
                        )
                    )
                    numericCache[key] = .failure(failure)
                    return .failure(failure)
                }
                guard let value = evaluatedValue(
                    calculation.operation,
                    values: values
                ) else {
                    let failure = EvaluationFailure(
                        message: AppLocalization.format(
                            "Calculation “%@” produced a non-finite value.",
                            sourceField.name
                        )
                    )
                    numericCache[key] = .failure(failure)
                    return .failure(failure)
                }
                numericCache[key] = .success(value)
                return .success(value)
            }

            guard let value = parseNumericValue(
                sourceField.value,
                format: rawFields[key]?.format
            ) else {
                let failure = EvaluationFailure(
                    message: AppLocalization.format(
                        "“%@” needs a valid number before calculations can run.",
                        sourceField.name
                    )
                )
                numericCache[key] = .failure(failure)
                return .failure(failure)
            }
            numericCache[key] = .success(value)
            return .success(value)
        }

        var automationFields: [PDFFormAutomationFieldSnapshot] = []
        automationFields.reserveCapacity(
            min(fields.count, rawFields.count)
        )
        for (fieldIndex, field) in fields.enumerated() {
            if fieldIndex.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let key = normalizedName(field.name)
            guard let raw = rawFields[key] else { continue }
            var expectedValue: String?
            var formattedPreview: String?
            var validationIssue: String?
            var needsUpdate = false

            if let calculation = raw.calculation {
                if field.kind != .text {
                    validationIssue =
                        "Calculated output requires a text field."
                } else {
                    var stack: Set<String> = []
                    switch try numericValue(
                        for: key,
                        stack: &stack
                    ) {
                    case .success(let value):
                        expectedValue = canonicalNumber(value)
                        if let format = raw.format {
                            if let preview = formattedValue(
                                value,
                                format: format
                            ) {
                                formattedPreview = preview
                            } else {
                                validationIssue = AppLocalization.format(
                                    "Calculation “%@” is too large for its display format.",
                                    field.name
                                )
                            }
                        } else {
                            formattedPreview = expectedValue
                        }
                        if validationIssue == nil {
                            if let current = parseNumericValue(
                                field.value,
                                format: raw.format
                            ) {
                                needsUpdate = !numbersMatch(
                                    current,
                                    value
                                )
                            } else {
                                needsUpdate = true
                            }
                        }
                    case .failure(let failure):
                        validationIssue = failure.message
                    }
                }
                _ = calculation
            } else if let format = raw.format,
                      let value = field.value?
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ),
                      !value.isEmpty {
                switch format.kind {
                case .number, .percent:
                    if let number = parseNumericValue(
                        value,
                        format: format
                    ) {
                        if let preview = formattedValue(
                            number,
                            format: format
                        ) {
                            formattedPreview = preview
                        } else {
                            validationIssue = AppLocalization.format(
                                "“%@” is too large for its display format.",
                                field.name
                            )
                        }
                    } else {
                        validationIssue = AppLocalization.format(
                            "“%@” is not a valid %@.",
                            field.name,
                            format.kind.title.localizedUI.lowercased()
                        )
                    }
                case .date, .time:
                    if let normalized = normalizedDateOrTime(
                        value,
                        format: format
                    ) {
                        formattedPreview = normalized
                    } else {
                        validationIssue = AppLocalization.format(
                            "“%@” does not match %@.",
                            field.name,
                            format.pattern
                                ?? format.kind.title.localizedUI
                        )
                    }
                }
            }

            if validationIssue == nil,
               let range = raw.rangeValidation,
               let value = parseNumericValue(
                   expectedValue ?? field.value,
                   format: raw.format
               ) {
                if let minimum = range.minimum,
                   value < minimum {
                    validationIssue = AppLocalization.format(
                        "“%@” must be at least %@.",
                        field.name,
                        canonicalNumber(minimum)
                    )
                } else if let maximum = range.maximum,
                          value > maximum {
                    validationIssue = AppLocalization.format(
                        "“%@” must be at most %@.",
                        field.name,
                        canonicalNumber(maximum)
                    )
                }
            } else if validationIssue == nil,
                      raw.rangeValidation != nil,
                      field.value?.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty == false {
                validationIssue = AppLocalization.format(
                    "“%@” needs a valid number for range validation.",
                    field.name
                )
            }
            automationFields.append(
                PDFFormAutomationFieldSnapshot(
                    fieldID: field.id,
                    fieldName: field.name,
                    calculation: raw.calculation,
                    format: raw.format,
                    rangeValidation: raw.rangeValidation,
                    expectedValue: expectedValue,
                    formattedPreview: formattedPreview,
                    needsUpdate: needsUpdate,
                    validationIssue: validationIssue,
                    unsupportedActionCount: raw.unsupportedActionCount
                )
            )
        }

        try Task.checkCancellation()
        return PDFFormAutomationInspection(
            fields: automationFields,
            encounteredJavaScriptCount: rawFields.values.reduce(0) {
                $0 + $1.encounteredActionCount
            },
            unsupportedJavaScriptCount: rawFields.values.reduce(0) {
                $0 + $1.unsupportedActionCount
            }
        )
    }

    private func rawAutomations(
        in document: CGPDFDocument
    ) throws -> [String: RawAutomation] {
        guard document.numberOfPages > 0 else { return [:] }
        var result: [String: RawAutomation] = [:]
        var scannedWidgetCount = 0
        for pageNumber in 1...document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: pageNumber),
                  let dictionary = page.dictionary
            else { throw PaperPathError.invalidPage }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(
                dictionary,
                "Annots",
                &annotations
            ),
                  let annotations
            else { continue }
            let count = CGPDFArrayGetCount(annotations)
            guard count <= maximumAnnotationsPerPage else {
                throw PaperPathError.insufficientSelection(
                    "A form page contains too many annotations to inspect scripted fields safely."
                )
            }
            for index in 0..<count {
                if index.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(
                    annotations,
                    index,
                    &annotation
                ),
                      let annotation,
                      pdfName(
                          in: annotation,
                          key: "Subtype"
                      )?.caseInsensitiveCompare("Widget")
                        == .orderedSame
                else { continue }
                scannedWidgetCount += 1
                guard scannedWidgetCount <= maximumAutomationWidgets else {
                    throw PaperPathError.insufficientSelection(
                        "This form contains too many scripted fields to inspect safely."
                    )
                }
                guard
                      let fieldName = inheritedString(
                          in: annotation,
                          key: "T"
                      )?.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ),
                      isSafeSingleLineText(
                          fieldName,
                          maximumCharacters: 160,
                          maximumBytes: 640
                      )
                else { continue }
                let scripts = inheritedScripts(in: annotation)
                let parsed = parsedAutomation(
                    fieldName: fieldName,
                    scripts: scripts
                )
                guard parsed.encounteredActionCount > 0 else {
                    continue
                }
                let key = normalizedName(fieldName)
                if let existing = result[key] {
                    result[key] = RawAutomation(
                        fieldName: existing.fieldName,
                        calculation: existing.calculation
                            ?? parsed.calculation,
                        format: existing.format ?? parsed.format,
                        rangeValidation: existing.rangeValidation
                            ?? parsed.rangeValidation,
                        encounteredActionCount: max(
                            existing.encounteredActionCount,
                            parsed.encounteredActionCount
                        ),
                        unsupportedActionCount: max(
                            existing.unsupportedActionCount,
                            parsed.unsupportedActionCount
                        )
                    )
                } else {
                    result[key] = parsed
                }
            }
        }
        return result
    }

    private func parsedAutomation(
        fieldName: String,
        scripts: [String: String]
    ) -> RawAutomation {
        var calculation: PDFFormCalculationRule?
        var format: PDFFormFormatRule?
        var rangeValidation: PDFFormRangeValidationRule?
        var unsupported = 0

        if let script = scripts["C"] {
            calculation = parseCalculation(script)
            if calculation == nil { unsupported += 1 }
        }
        if let script = scripts["F"] {
            format = parseFormat(script)
            if format == nil { unsupported += 1 }
        }
        if let script = scripts["V"] {
            rangeValidation = parseRangeValidation(script)
            if rangeValidation == nil { unsupported += 1 }
        }
        if let script = scripts["K"],
           !isRecognizedKeystroke(script) {
            unsupported += 1
        }
        if scripts["A"] != nil {
            unsupported += 1
        }
        return RawAutomation(
            fieldName: fieldName,
            calculation: calculation,
            format: format,
            rangeValidation: rangeValidation,
            encounteredActionCount: scripts.count,
            unsupportedActionCount: unsupported
        )
    }

    private func inheritedScripts(
        in dictionary: CGPDFDictionaryRef
    ) -> [String: String] {
        var scripts: [String: String] = [:]
        var current: CGPDFDictionaryRef? = dictionary
        var depth = 0
        while let node = current, depth < 12 {
            if let additionalActions = pdfDictionary(
                in: node,
                key: "AA"
            ) {
                for key in ["C", "F", "V", "K"]
                    where scripts[key] == nil {
                    if let payload = javaScript(
                        in: additionalActions,
                        key: key
                    ) {
                        scripts[key] = payload.sourceForInspection
                    }
                }
            }
            if scripts["A"] == nil,
               let payload = javaScript(in: node, key: "A") {
                scripts["A"] = payload.sourceForInspection
            }
            current = pdfDictionary(in: node, key: "Parent")
            depth += 1
        }
        if current != nil {
            scripts["A"] = scripts["A"] ?? ""
        }
        return scripts
    }

    private func inheritedString(
        in dictionary: CGPDFDictionaryRef,
        key: String
    ) -> String? {
        var current: CGPDFDictionaryRef? = dictionary
        var depth = 0
        while let node = current, depth < 12 {
            if let value = pdfString(in: node, key: key) {
                return value
            }
            current = pdfDictionary(in: node, key: "Parent")
            depth += 1
        }
        return nil
    }

    private func javaScript(
        in dictionary: CGPDFDictionaryRef,
        key: String
    ) -> JavaScriptPayload? {
        guard let action = pdfDictionary(
            in: dictionary,
            key: key
        ),
              pdfName(in: action, key: "S")?
                .caseInsensitiveCompare("JavaScript")
                == .orderedSame
        else { return nil }
        if let value = pdfString(in: action, key: "JS") {
            return boundedScript(value)
                .map(JavaScriptPayload.source)
                ?? .unsupported
        }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(
            action,
            "JS",
            &stream
        ),
              stream != nil
        else { return .unsupported }
        // Core Graphics only exposes decoded stream bytes as one allocation.
        // Preserve stream-backed JavaScript without inspecting it so a
        // compressed payload cannot create an unbounded memory spike.
        return .unsupported
    }

    func boundedScript(_ value: String) -> String? {
        guard value.count <= maximumScriptCharacters,
              value.utf8.count <= maximumScriptBytes
        else { return nil }
        return value
    }

    func decodedScript(_ data: Data) -> String? {
        if data.starts(with: [0xfe, 0xff]) {
            let values = stride(
                from: 2,
                to: data.count - 1,
                by: 2
            ).map {
                UInt16(data[$0]) << 8 | UInt16(data[$0 + 1])
            }
            return String(decoding: values, as: UTF16.self)
        }
        if data.starts(with: [0xff, 0xfe]) {
            let values = stride(
                from: 2,
                to: data.count - 1,
                by: 2
            ).map {
                UInt16(data[$0 + 1]) << 8 | UInt16(data[$0])
            }
            return String(decoding: values, as: UTF16.self)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    func parseCalculation(
        _ script: String
    ) -> PDFFormCalculationRule? {
        guard let call = singleCall(script),
              call.name == "AFSimple_Calculate",
              call.arguments.count == 2,
              let operationName = javaScriptString(
                  call.arguments[0]
              )?.uppercased(),
              let operation = calculationOperation(
                  operationName
              ),
              let sources = javaScriptStringArray(
                  call.arguments[1]
              ),
              (1...64).contains(sources.count),
              sources.allSatisfy({
                  isSafeSingleLineText(
                      $0,
                      maximumCharacters: 160,
                      maximumBytes: 640
                  )
              })
        else { return nil }
        return PDFFormCalculationRule(
            operation: operation,
            sourceFieldNames: sources
        )
    }

    func calculationOperation(
        _ value: String
    ) -> PDFFormCalculationOperation? {
        switch value {
        case "SUM": return .sum
        case "PRD": return .product
        case "AVG": return .average
        case "MIN": return .minimum
        case "MAX": return .maximum
        default: return nil
        }
    }

    func parseFormat(
        _ script: String
    ) -> PDFFormFormatRule? {
        guard let call = singleCall(script) else { return nil }
        switch call.name {
        case "AFNumber_Format":
            guard call.arguments.count == 6,
                  let decimals = integer(call.arguments[0]),
                  (0...10).contains(decimals),
                  let separator = integer(call.arguments[1]),
                  (0...4).contains(separator),
                  let negative = integer(call.arguments[2]),
                  (0...3).contains(negative),
                  let currencyStyle = integer(call.arguments[3]),
                  (0...1).contains(currencyStyle),
                  let currency = javaScriptString(
                      call.arguments[4]
                  ),
                  isSafeSingleLineText(
                      currency,
                      maximumCharacters: 12,
                      maximumBytes: 48,
                      allowsEmpty: true
                  ),
                  let precedes = boolean(call.arguments[5])
            else { return nil }
            return PDFFormFormatRule(
                kind: .number,
                decimalPlaces: decimals,
                separatorStyle: separator,
                negativeStyle: negative,
                currencySymbol: currency,
                currencyPrecedesValue: precedes,
                pattern: nil
            )
        case "AFPercent_Format":
            guard call.arguments.count == 2,
                  let decimals = integer(call.arguments[0]),
                  (0...10).contains(decimals),
                  let separator = integer(call.arguments[1]),
                  (0...4).contains(separator)
            else { return nil }
            return PDFFormFormatRule(
                kind: .percent,
                decimalPlaces: decimals,
                separatorStyle: separator,
                negativeStyle: 0,
                currencySymbol: "",
                currencyPrecedesValue: true,
                pattern: nil
            )
        case "AFDate_FormatEx", "AFTime_FormatEx":
            guard call.arguments.count == 1,
                  let pattern = javaScriptString(
                      call.arguments[0]
                  ),
                  supportedDatePattern(
                      pattern,
                      isTime: call.name == "AFTime_FormatEx"
                  ) != nil
            else { return nil }
            return PDFFormFormatRule(
                kind: call.name == "AFTime_FormatEx"
                    ? .time
                    : .date,
                decimalPlaces: 0,
                separatorStyle: 0,
                negativeStyle: 0,
                currencySymbol: "",
                currencyPrecedesValue: true,
                pattern: pattern
            )
        default:
            return nil
        }
    }

    func parseRangeValidation(
        _ script: String
    ) -> PDFFormRangeValidationRule? {
        guard let call = singleCall(script),
              call.name == "AFRange_Validate",
              call.arguments.count == 4,
              let hasMinimum = boolean(call.arguments[0]),
              let minimum = double(call.arguments[1]),
              let hasMaximum = boolean(call.arguments[2]),
              let maximum = double(call.arguments[3]),
              (!hasMinimum || !hasMaximum || minimum <= maximum)
        else { return nil }
        return PDFFormRangeValidationRule(
            minimum: hasMinimum ? minimum : nil,
            maximum: hasMaximum ? maximum : nil
        )
    }

    func isRecognizedKeystroke(
        _ script: String
    ) -> Bool {
        guard let call = singleCall(script) else { return false }
        switch call.name {
        case "AFNumber_Keystroke":
            return call.arguments.count == 6
                && integer(call.arguments[0]).map {
                    (0...10).contains($0)
                } == true
                && integer(call.arguments[1]).map {
                    (0...4).contains($0)
                } == true
                && integer(call.arguments[2]).map {
                    (0...3).contains($0)
                } == true
                && integer(call.arguments[3]).map {
                    (0...1).contains($0)
                } == true
                && javaScriptString(call.arguments[4]).map {
                    isSafeSingleLineText(
                        $0,
                        maximumCharacters: 12,
                        maximumBytes: 48,
                        allowsEmpty: true
                    )
                } == true
                && boolean(call.arguments[5]) != nil
        case "AFPercent_Keystroke":
            return call.arguments.count == 2
                && integer(call.arguments[0]).map {
                    (0...10).contains($0)
                } == true
                && integer(call.arguments[1]).map {
                    (0...4).contains($0)
                } == true
        case "AFDate_KeystrokeEx", "AFTime_KeystrokeEx":
            guard call.arguments.count == 1,
                  let pattern = javaScriptString(
                      call.arguments[0]
                  )
            else { return false }
            return supportedDatePattern(
                pattern,
                isTime: call.name == "AFTime_KeystrokeEx"
            ) != nil
        default:
            return false
        }
    }

    private func singleCall(_ script: String) -> ScriptCall? {
        var value = script.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        while value.last == ";" {
            value.removeLast()
            value = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
        guard let open = value.firstIndex(of: "(") else {
            return nil
        }
        let name = value[..<open].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty,
              name.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "_"
              })
        else { return nil }
        var index = value.index(after: open)
        var depth = 1
        var quote: Character?
        var escaped = false
        var close: String.Index?
        while index < value.endIndex {
            let character = value[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    close = index
                    break
                }
            }
            index = value.index(after: index)
        }
        guard let close,
              value[value.index(after: close)...]
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty,
              let arguments = splitArguments(
                  String(value[value.index(after: open)..<close])
              )
        else { return nil }
        return ScriptCall(
            name: String(name),
            arguments: arguments
        )
    }

    private func splitArguments(_ value: String) -> [String]? {
        guard !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else { return [] }
        var result: [String] = []
        var start = value.startIndex
        var index = value.startIndex
        var parenthesisDepth = 0
        var arrayDepth = 0
        var quote: Character?
        var escaped = false
        while index < value.endIndex {
            let character = value[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                guard parenthesisDepth > 0 else { return nil }
                parenthesisDepth -= 1
            } else if character == "[" {
                arrayDepth += 1
            } else if character == "]" {
                guard arrayDepth > 0 else { return nil }
                arrayDepth -= 1
            } else if character == ",",
                      parenthesisDepth == 0,
                      arrayDepth == 0 {
                guard result.count < 128 else { return nil }
                result.append(
                    String(value[start..<index])
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                )
                start = value.index(after: index)
            }
            index = value.index(after: index)
        }
        guard quote == nil,
              !escaped,
              parenthesisDepth == 0,
              arrayDepth == 0,
              result.count < 128
        else { return nil }
        result.append(
            String(value[start...])
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        )
        return result
    }

    func javaScriptStringArray(
        _ value: String
    ) -> [String]? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let inner: String
        if trimmed.hasPrefix("new Array("),
           trimmed.hasSuffix(")") {
            inner = String(
                trimmed.dropFirst("new Array(".count).dropLast()
            )
        } else if trimmed.hasPrefix("["),
                  trimmed.hasSuffix("]") {
            inner = String(trimmed.dropFirst().dropLast())
        } else if let single = javaScriptString(trimmed) {
            return [single]
        } else {
            return nil
        }
        guard let arguments = splitArguments(inner) else {
            return nil
        }
        let values = arguments.compactMap(javaScriptString)
        return values.count == arguments.count ? values : nil
    }

    func javaScriptString(
        _ value: String
    ) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.count >= 2,
              let quote = trimmed.first,
              (quote == "\"" || quote == "'"),
              trimmed.last == quote
        else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        var result = ""
        var escaped = false
        for character in inner {
            if escaped {
                switch character {
                case "\\", "\"", "'":
                    result.append(character)
                case "n":
                    result.append("\n")
                case "r":
                    result.append("\r")
                case "t":
                    result.append("\t")
                default:
                    return nil
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return escaped ? nil : result
    }

    func integer(_ value: String) -> Int? {
        Int(
            value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
    }

    func double(_ value: String) -> Double? {
        guard let result = Double(
            value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        ),
              result.isFinite
        else { return nil }
        return result
    }

    func boolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    func isSafeSingleLineText(
        _ value: String,
        maximumCharacters: Int,
        maximumBytes: Int,
        allowsEmpty: Bool = false
    ) -> Bool {
        guard allowsEmpty || !value.isEmpty,
              value.count <= maximumCharacters,
              value.utf8.count <= maximumBytes
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                codePoint == 0x061C
                || codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            return !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && !isBidirectionalControl
        }
    }

    func evaluatedValue(
        _ operation: PDFFormCalculationOperation,
        values: [Double]
    ) -> Double? {
        guard !values.isEmpty,
              values.allSatisfy(\.isFinite)
        else { return nil }
        switch operation {
        case .sum:
            return finiteSum(values)
        case .product:
            var result = 1.0
            for value in values {
                result *= value
                guard result.isFinite else { return nil }
            }
            return result
        case .average:
            let divisor = Double(values.count)
            return finiteSum(values.map { $0 / divisor })
        case .minimum:
            return values.min()
        case .maximum:
            return values.max()
        }
    }

    func finiteSum(_ values: [Double]) -> Double? {
        var result = 0.0
        for value in values {
            result += value
            guard result.isFinite else { return nil }
        }
        return result
    }

    func numbersMatch(
        _ left: Double,
        _ right: Double
    ) -> Bool {
        guard left.isFinite, right.isFinite else { return false }
        let difference = abs(left - right)
        guard difference.isFinite else { return false }
        return difference
            <= max(0.000_000_1, abs(right) * 0.000_000_1)
    }

    func canonicalNumber(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let magnitude = abs(value)
        if value.rounded() == value,
           magnitude <= Double(Int64.max) {
            return String(Int64(value.rounded()))
        }
        if magnitude >= 1_000_000_000_000_000
            || (magnitude > 0 && magnitude < 0.000_000_001) {
            return String(
                format: "%.17g",
                locale: Locale(identifier: "en_US_POSIX"),
                value
            )
        }
        return String(
            format: "%.10f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        ).replacingOccurrences(
            of: #"(\.\d*?[1-9])0+$|\.0+$"#,
            with: "$1",
            options: .regularExpression
        )
    }

    func parseNumericValue(
        _ rawValue: String?,
        format: PDFFormFormatRule?
    ) -> Double? {
        guard var value = rawValue?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
              !value.isEmpty
        else { return nil }
        if let symbol = format?.currencySymbol,
           !symbol.isEmpty {
            value = value.replacingOccurrences(
                of: symbol,
                with: ""
            )
            let compactSymbol = symbol.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !compactSymbol.isEmpty, compactSymbol != symbol {
                value = value.replacingOccurrences(
                    of: compactSymbol,
                    with: ""
                )
            }
        }
        let containsPercent = value.contains("%")
        value = value.replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        var isNegative = false
        if value.hasPrefix("("), value.hasSuffix(")") {
            isNegative = true
            value.removeFirst()
            value.removeLast()
        }

        let separatorStyle = format?.separatorStyle
        switch separatorStyle {
        case 2, 3:
            value = value.replacingOccurrences(of: ".", with: "")
            value = value.replacingOccurrences(of: ",", with: ".")
        case 4:
            value = value.replacingOccurrences(of: "'", with: "")
            value = value.replacingOccurrences(of: ",", with: "")
        case 0:
            value = value.replacingOccurrences(of: ",", with: "")
        case 1:
            break
        default:
            if value.contains(","), value.contains(".") {
                guard let comma = value.lastIndex(of: ","),
                      let period = value.lastIndex(of: ".")
                else { return nil }
                if comma > period {
                    value = value.replacingOccurrences(of: ".", with: "")
                    value = value.replacingOccurrences(of: ",", with: ".")
                } else {
                    value = value.replacingOccurrences(of: ",", with: "")
                }
            } else if value.contains(",") {
                let suffix = value.split(separator: ",").last?.count ?? 0
                value = suffix <= 2
                    ? value.replacingOccurrences(of: ",", with: ".")
                    : value.replacingOccurrences(of: ",", with: "")
            }
        }
        guard var number = Double(value), number.isFinite else {
            return nil
        }
        if isNegative { number = -abs(number) }
        if containsPercent { number /= 100 }
        return number
    }

    func formattedValue(
        _ value: Double,
        format: PDFFormFormatRule
    ) -> String? {
        guard value.isFinite else { return nil }
        switch format.kind {
        case .date, .time:
            return canonicalNumber(value)
        case .number, .percent:
            let displayValue = format.kind == .percent
                ? value * 100
                : value
            guard displayValue.isFinite else { return nil }
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = format.decimalPlaces
            formatter.maximumFractionDigits = format.decimalPlaces
            formatter.usesGroupingSeparator = ![1, 3]
                .contains(format.separatorStyle)
            switch format.separatorStyle {
            case 2, 3:
                formatter.groupingSeparator = "."
                formatter.decimalSeparator = ","
            case 4:
                formatter.groupingSeparator = "'"
                formatter.decimalSeparator = "."
            default:
                formatter.groupingSeparator = ","
                formatter.decimalSeparator = "."
            }
            guard let absolute = formatter.string(
                from: NSNumber(value: abs(displayValue))
            ),
                  absolute.count <= 256,
                  absolute.utf8.count <= 1_024
            else { return nil }
            var decorated = absolute
            if format.kind == .percent {
                decorated += "%"
            } else if !format.currencySymbol.isEmpty {
                decorated = format.currencyPrecedesValue
                    ? format.currencySymbol + decorated
                    : decorated + format.currencySymbol
            }
            let result: String
            if displayValue < 0, format.negativeStyle >= 2 {
                result = "(\(decorated))"
            } else if displayValue < 0 {
                result = "-\(decorated)"
            } else {
                result = decorated
            }
            guard result.count <= 272,
                  result.utf8.count <= 1_088
            else { return nil }
            return result
        }
    }

    func normalizedDateOrTime(
        _ value: String,
        format: PDFFormFormatRule
    ) -> String? {
        guard let pattern = format.pattern,
              let dateFormat = supportedDatePattern(
                  pattern,
                  isTime: format.kind == .time
              )
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = dateFormat
        guard let date = formatter.date(from: value) else {
            return nil
        }
        return formatter.string(from: date)
    }

    func supportedDatePattern(
        _ pattern: String,
        isTime: Bool
    ) -> String? {
        let trimmed = pattern.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if isTime {
            switch trimmed {
            case "HH:MM": return "HH:mm"
            case "h:MM tt": return "h:mm a"
            case "hh:MM tt": return "hh:mm a"
            case "HH:MM:ss": return "HH:mm:ss"
            case "h:MM:ss tt": return "h:mm:ss a"
            default: return nil
            }
        }
        switch trimmed {
        case "m/d", "mm/dd":
            return trimmed == "m/d" ? "M/d" : "MM/dd"
        case "m/d/yy", "mm/dd/yy", "m/d/yyyy", "mm/dd/yyyy":
            return trimmed
                .replacingOccurrences(of: "mm", with: "MM")
                .replacingOccurrences(of: "m", with: "M")
        case "d-mmm", "d-mmm-yy", "dd-mmm-yy",
             "d-mmm-yyyy", "dd-mmm-yyyy":
            return trimmed.replacingOccurrences(of: "mmm", with: "MMM")
        case "mmm d, yyyy", "mmmm d, yyyy":
            return trimmed
                .replacingOccurrences(of: "mmmm", with: "MMMM")
                .replacingOccurrences(of: "mmm", with: "MMM")
        default:
            return nil
        }
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

private func pdfString(
    in dictionary: CGPDFDictionaryRef,
    key: String
) -> String? {
    var value: CGPDFStringRef?
    guard CGPDFDictionaryGetString(
        dictionary,
        key,
        &value
    ),
          let value,
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
