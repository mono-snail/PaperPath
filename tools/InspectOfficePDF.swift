import Foundation
import PDFKit

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let document = PDFDocument(url: url)!
let index = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! - 1 : 0
let page = document.page(at: index)!
let text = page.string ?? ""
let selection = page.selection(for: NSRange(location: 0, length: (text as NSString).length))
let source = text as NSString
let words = try NSRegularExpression(pattern: "\\S+")
let selections = CommandLine.arguments.contains("--words")
    ? words.matches(in: text, range: NSRange(location: 0, length: source.length))
        .compactMap { page.selection(for: $0.range) }
    : selection?.selectionsByLine() ?? []
for line in selections {
    let bounds = line.bounds(for: page)
    print(String(format: "x=%7.2f y=%7.2f w=%7.2f h=%6.2f", bounds.minX, bounds.minY, bounds.width, bounds.height), (line.string ?? "").debugDescription)
}
