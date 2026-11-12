#if DEBUG && !PAPERPATH_REVIEW_BUILD
import Foundation

/// References are stable for this conversation. Zero means the preceding step's output.
struct PDFAssistantFile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let number: Int
    let name: String
    let revisionID: UUID
    let pageCount: Int
    let isLocked: Bool
}

enum PDFAssistantAction: String, Codable, Hashable, Sendable {
    case merge, extract, compress
    var title: String {
        switch self {
        case .merge: return "Combine PDFs"
        case .extract: return "Extract pages"
        case .compress: return "Compress a copy"
        }
    }
}

struct PDFAssistantStep: Codable, Equatable, Sendable {
    let action: PDFAssistantAction
    let inputs: [Int]
    let firstPage: Int
    let lastPage: Int
}

struct PDFAssistantPlan: Identifiable, Sendable {
    let id = UUID()
    let files: [PDFAssistantFile]
    let steps: [PDFAssistantStep]
    let usesLanguageModel: Bool

    /// Validate every step, including intermediate page counts, before any PDF is touched.
    func validate() throws {
        guard (1...16).contains(files.count), (1...4).contains(steps.count),
              Set(files.map(\.number)).count == files.count,
              Set(files.map(\.id)).count == files.count,
              files.allSatisfy({ $0.number > 0 && $0.pageCount > 0 && !$0.isLocked }) else {
            throw PDFAssistantError.invalidPlan
        }
        let sources = Dictionary(uniqueKeysWithValues: files.map { ($0.number, $0.pageCount) })
        var previousPages: Int?
        for step in steps {
            guard !step.inputs.isEmpty, step.inputs.count <= 16,
                  Set(step.inputs).count == step.inputs.count else { throw PDFAssistantError.invalidPlan }
            let pageCounts = try step.inputs.map { number -> Int in
                guard let count = number == 0 ? previousPages : sources[number] else { throw PDFAssistantError.invalidPlan }
                return count
            }
            switch step.action {
            case .merge:
                guard step.inputs.count >= 2, step.firstPage == 0, step.lastPage == 0 else { throw PDFAssistantError.invalidPlan }
                var count = 0
                for pages in pageCounts {
                    let (sum, overflow) = count.addingReportingOverflow(pages)
                    guard !overflow, sum <= 100_000 else { throw PDFAssistantError.invalidPlan }
                    count = sum
                }
                previousPages = count
            case .extract:
                guard pageCounts.count == 1, step.firstPage >= 1,
                      step.lastPage >= step.firstPage, step.lastPage <= pageCounts[0] else { throw PDFAssistantError.invalidPages }
                previousPages = step.lastPage - step.firstPage + 1
            case .compress:
                guard pageCounts.count == 1, step.firstPage == 0, step.lastPage == 0 else { throw PDFAssistantError.invalidPlan }
                previousPages = pageCounts[0]
            }
        }
    }
}

enum PDFAssistantError: Error, LocalizedError {
    case invalidPlan, invalidPages, changedFiles, unavailable, failedOperation
    var errorDescription: String? {
        switch self {
        case .invalidPlan: return "The proposed steps need clarification. Please specify the file numbers and operation.".localizedUI
        case .invalidPages: return "The page range is outside the selected PDF. Please specify a valid range.".localizedUI
        case .changedFiles: return "A selected PDF changed. Please prepare the steps again.".localizedUI
        case .unavailable: return "The on-device model is unavailable. You can still use Quick actions.".localizedUI
        case .failedOperation: return "The PDF operation did not finish. Completed copies remain in your library.".localizedUI
        }
    }
}

/// UTF-16 offsets match UITextView; never split Chinese/emoji or replace text outside the caret.
enum PDFAssistantReferences {
    static func activeRange(text: String, selection: NSRange) -> NSRange? {
        let ns = text as NSString
        guard selection.length == 0, selection.location >= 0, selection.location <= ns.length,
              Range(selection, in: text) != nil else { return nil }
        let prefix = ns.substring(to: selection.location)
        guard let range = prefix.range(of: #"(?<![A-Za-z0-9_])#[0-9]*$"#, options: .regularExpression) else { return nil }
        return NSRange(range, in: prefix)
    }

    static func inserting(number: Int, text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let valid = selection.location >= 0 && selection.location <= ns.length && selection.length >= 0
            && selection.length <= ns.length - selection.location && Range(selection, in: text) != nil
        let safe = valid ? selection : NSRange(location: ns.length, length: 0)
        let replaced = activeRange(text: text, selection: safe) ?? safe
        let leadingSpace = replaced.location > 0 && !ns.substring(to: replaced.location).hasSuffix(" ")
            && activeRange(text: text, selection: safe) == nil
        let token = (leadingSpace ? " " : "") + "#\(number) "
        return (ns.replacingCharacters(in: replaced, with: token), NSRange(location: replaced.location + token.utf16.count, length: 0))
    }
}

#endif
