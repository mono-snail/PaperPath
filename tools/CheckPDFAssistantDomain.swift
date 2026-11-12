import Foundation

// Host-only validation. Does not start a simulator or load a language model.
extension String { var localizedUI: String { self } }

@main
struct CheckPDFAssistantDomain {
    static func main() throws {
        let files = [
            PDFAssistantFile(id: UUID(), number: 1, name: "合同.pdf", revisionID: UUID(), pageCount: 8, isLocked: false),
            PDFAssistantFile(id: UUID(), number: 2, name: "附件.pdf", revisionID: UUID(), pageCount: 5, isLocked: false)
        ]
        func check(_ steps: [PDFAssistantStep], valid: Bool, sources: [PDFAssistantFile]? = nil) {
            do {
                try PDFAssistantPlan(files: sources ?? files, steps: steps, usesLanguageModel: true).validate()
                precondition(valid, "Unexpectedly accepted invalid plan")
            } catch { precondition(!valid, "Rejected valid plan: \(error)") }
        }
        check([.init(action: .merge, inputs: [2, 1], firstPage: 0, lastPage: 0),
               .init(action: .compress, inputs: [0], firstPage: 0, lastPage: 0),
               .init(action: .extract, inputs: [0], firstPage: 9, lastPage: 13)], valid: true)
        check([.init(action: .compress, inputs: [0], firstPage: 0, lastPage: 0)], valid: false)
        check([.init(action: .merge, inputs: [1, 1], firstPage: 0, lastPage: 0)], valid: false)
        check([.init(action: .compress, inputs: [3], firstPage: 0, lastPage: 0)], valid: false)
        check([.init(action: .extract, inputs: [1], firstPage: 0, lastPage: 2)], valid: false)
        check([.init(action: .extract, inputs: [1], firstPage: 7, lastPage: 9)], valid: false)
        check([.init(action: .compress, inputs: [1, 2], firstPage: 0, lastPage: 0)], valid: false)
        check([.init(action: .merge, inputs: [1, 2], firstPage: 1, lastPage: 2)], valid: false)
        check([], valid: false)
        check([.init(action: .merge, inputs: [1, 2], firstPage: 0, lastPage: 0)], valid: false,
              sources: [files[0], .init(id: files[1].id, number: 2, name: "Locked", revisionID: UUID(), pageCount: 5, isLocked: true)])
        check([.init(action: .merge, inputs: [1, 2], firstPage: 0, lastPage: 0)], valid: false,
              sources: [files[0], .init(id: files[0].id, number: 2, name: "Duplicate", revisionID: UUID(), pageCount: 5, isLocked: false)])
        for first in 1...8 {
            for last in first...10 {
                check([.init(action: .extract, inputs: [1], firstPage: first, lastPage: last),
                       .init(action: .extract, inputs: [0], firstPage: 1, lastPage: last - first + 1)], valid: last <= 8)
            }
        }
        func insert(_ text: String, _ range: NSRange, _ number: Int, expected: String) {
            let result = PDFAssistantReferences.inserting(number: number, text: text, selection: range)
            precondition(result.text == expected, "Reference mismatch: \(result.text)")
            precondition(Range(result.selection, in: result.text) != nil)
        }
        insert("合并 #1 和 ", NSRange(location: "合并 #1 和 ".utf16.count, length: 0), 2, expected: "合并 #1 和 #2 ")
        insert("压缩 #1", NSRange(location: "压缩 #1".utf16.count, length: 0), 3, expected: "压缩 #3 ")
        insert("处理📄然后", NSRange(location: "处理📄".utf16.count, length: 0), 3, expected: "处理📄 #3 然后")
        insert("合并旧文件", NSRange(location: 2, length: 3), 5, expected: "合并 #5 ")
        insert("压缩", NSRange(location: NSNotFound, length: 0), 8, expected: "压缩 #8 ")
        precondition(PDFAssistantReferences.activeRange(text: "合并#", selection: NSRange(location: 3, length: 0)) != nil)
        precondition(PDFAssistantReferences.activeRange(text: "abc#1", selection: NSRange(location: 5, length: 0)) == nil)
        print("PASS: multi-step plan validation, source references, chained page bounds, and UTF-16 reference editing")
    }
}
