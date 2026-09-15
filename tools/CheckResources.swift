import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let roots = ["PaperPath", "PaperPathShareExtension"]
let plistExtensions: Set<String> = ["plist", "strings", "xcprivacy", "entitlements"]
let keyPattern = try NSRegularExpression(
    pattern: #"(?m)^\s*("(?:[^"\\]|\\.)*")\s*="#
)
var fileCount = 0
var localizedKeyCount = 0
var failures: [String] = []

for directory in roots {
    guard let files = FileManager.default.enumerator(
        at: root.appendingPathComponent(directory),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { fatalError("Missing source directory: \(directory)") }
    for case let url as URL in files {
        let ext = url.pathExtension
        guard plistExtensions.contains(ext) || ext == "json" else { continue }
        do {
            let data = try Data(contentsOf: url)
            if ext == "json" {
                _ = try JSONSerialization.jsonObject(with: data)
            } else {
                _ = try PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                )
            }
            if ext == "strings" {
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                let source = text as NSString
                var keys: Set<String> = []
                for match in keyPattern.matches(
                    in: text, range: NSRange(location: 0, length: source.length)
                ) {
                    let literal = source.substring(with: match.range(at: 1))
                    let entry = Data("\(literal) = \"\";".utf8)
                    let decoded = try PropertyListSerialization.propertyList(
                        from: entry, options: [], format: nil
                    ) as! [String: String]
                    let key = decoded.keys.first!
                    if !keys.insert(key).inserted {
                        failures.append("\(url.lastPathComponent): duplicate key \(key)")
                    }
                }
                localizedKeyCount += keys.count
            }
            fileCount += 1
        } catch {
            failures.append("\(url.path): \(error.localizedDescription)")
        }
    }
}

if failures.isEmpty {
    print("PASS: \(fileCount) resource files parsed; \(localizedKeyCount) unique localization keys (per file).")
} else {
    failures.forEach { print("FAIL: \($0)") }
    exit(1)
}
