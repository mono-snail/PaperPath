import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    static let defaultsKey = "app.language"

    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return AppLocalization.string("System Language")
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "iphone"
        case .english: return "character.book.closed"
        case .simplifiedChinese: return "character.book.closed.zh"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        }
    }
}

enum AppLocalization {
    static var selectedLanguage: AppLanguage {
        let rawValue = UserDefaults.standard.string(
            forKey: AppLanguage.defaultsKey
        ) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static func string(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        switch selectedLanguage {
        case .english:
            return key
        case .simplifiedChinese:
            return simplifiedChineseString(
                key,
                bundle: bundle(
                    languageCode:
                        AppLanguage.simplifiedChinese.rawValue
                )
            )
        case .system:
            let localized = Bundle.main.localizedString(
                forKey: key,
                value: key,
                table: "Localizable"
            )
            guard localized == key,
                  Locale.preferredLanguages.first?
                    .hasPrefix("zh") == true
            else { return localized }
            return simplifiedChinesePattern(key) ?? key
        }
    }

    static func format(
        _ key: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: string(key),
            locale: selectedLanguage.locale,
            arguments: arguments
        )
    }

    private static func bundle(
        languageCode: String
    ) -> Bundle? {
        guard let path = Bundle.main.path(
            forResource: languageCode,
            ofType: "lproj"
        ),
        let bundle = Bundle(path: path)
        else { return nil }
        return bundle
    }

    private static func simplifiedChineseString(
        _ key: String,
        bundle: Bundle?
    ) -> String {
        let localized = bundle?.localizedString(
            forKey: key,
            value: key,
            table: "Localizable"
        ) ?? key
        guard localized == key else { return localized }
        return simplifiedChinesePattern(key) ?? key
    }

    private static func simplifiedChinesePattern(
        _ value: String
    ) -> String? {
        if let checkpoint = localizedCheckpointReason(value) {
            return checkpoint
        }
        if let count = integer(
            in: value,
            prefix: "Review ",
            suffixes: [" form field", " form fields"]
        ) {
            return "检查 \(count) 个表单字段"
        }
        if let count = integer(
            in: value,
            prefix: "This working copy contains ",
            suffixes: [" page.", " pages."]
        ) {
            return "此工作副本包含 \(count) 页。"
        }
        if let count = integer(
            in: value,
            prefix: "A ",
            suffixes: [
                "-page image-based document. Recognize text to reveal facts and make it searchable."
            ]
        ) {
            return "这是一份 \(count) 页的图像型文档。识别文字后即可提取信息并进行搜索。"
        }
        if let count = integer(
            in: value,
            prefix: "Text is indexed locally with ",
            suffixes: [
                " detected fact to review.",
                " detected facts to review."
            ]
        ) {
            return "文本已在本机建立索引，有 \(count) 条检测信息待检查。"
        }
        if let result = localizedClassificationSummary(value) {
            return result
        }
        if let count = integer(
            in: value,
            prefix: "All ",
            suffixes: [" page rendered", " pages rendered"]
        ) {
            return "全部 \(count) 页均已渲染"
        }
        if let counts = twoIntegers(
            in: value,
            prefix: "",
            middle: " of ",
            suffix: " pages rendered"
        ) {
            return "已渲染 \(counts.first) 页，共 \(counts.second) 页"
        }
        if let counts = twoIntegers(
            in: value,
            prefix: "",
            middle: " of ",
            suffix: " pages retained"
        ) {
            return "已保留 \(counts.first) 页，共 \(counts.second) 页"
        }
        if let counts = twoIntegers(
            in: value,
            prefix: "Expected ",
            middle: " pages; found ",
            suffix: ""
        ) {
            return "预期 \(counts.first) 页，实际 \(counts.second) 页"
        }
        let auditCountPatterns: [
            (prefix: String, suffixes: [String], result: (Int) -> String)
        ] = [
            (
                "",
                [
                    " annotation will be flattened",
                    " annotations will be flattened"
                ],
                { "\($0) 个批注将被扁平化" }
            ),
            (
                "",
                [" entry will be removed", " entries will be removed"],
                { "\($0) 条元数据将被移除" }
            ),
            (
                "",
                [
                    " searchable character will be removed",
                    " searchable characters will be removed"
                ],
                { "\($0) 个可搜索字符将被移除" }
            ),
            (
                "",
                [
                    " editable annotation remains",
                    " editable annotations remain"
                ],
                { "仍有 \($0) 个可编辑批注" }
            ),
            (
                "",
                [" annotation retained", " annotations retained"],
                { "已保留 \($0) 个批注" }
            ),
            (
                "",
                [" text character remains", " text characters remain"],
                { "仍有 \($0) 个文本字符" }
            ),
            (
                "",
                [
                    " personal metadata entry remains",
                    " personal metadata entries remain"
                ],
                { "仍有 \($0) 条个人元数据" }
            ),
            (
                "",
                [
                    " entry retained by password protection",
                    " entries retained by password protection"
                ],
                { "密码保护保留了 \($0) 条元数据" }
            )
        ]
        for pattern in auditCountPatterns {
            if let count = integer(
                in: value,
                prefix: pattern.prefix,
                suffixes: pattern.suffixes
            ) {
                return pattern.result(count)
            }
        }
        let creationPrefix = "Creation may take longer for "
        if value.hasPrefix(creationPrefix) {
            return "创建 \(value.dropFirst(creationPrefix.count)) 文件可能需要更长时间"
        }
        let countPatterns: [
            (prefix: String, suffixes: [String], result: (Int) -> String)
        ] = [
            (
                "",
                [" page ready to extract", " pages ready to extract"],
                { "\($0) 页可提取" }
            ),
            (
                "",
                [" page ready to organize", " pages ready to organize"],
                { "\($0) 页可整理" }
            ),
            (
                "",
                [" page", " pages"],
                { "\($0) 页" }
            ),
            (
                "",
                [" page to render", " pages to render"],
                { "\($0) 页待渲染" }
            ),
            (
                "",
                [" interactive field", " interactive fields"],
                { "\($0) 个交互式字段" }
            )
        ]
        for pattern in countPatterns {
            if let count = integer(
                in: value,
                prefix: pattern.prefix,
                suffixes: pattern.suffixes
            ) {
                return pattern.result(count)
            }
        }
        return nil
    }

    private static func localizedCheckpointReason(
        _ value: String
    ) -> String? {
        let reasons = [
            (
                "Return to the next required field",
                "返回下一个必填字段"
            ),
            (
                "Return to the saved signature position",
                "返回已保存的签名位置"
            ),
            (
                "Check the final copy before sharing",
                "分享前检查最终副本"
            )
        ]
        for (source, localized) in reasons {
            let fieldPrefix = "\(source): "
            if value.hasPrefix(fieldPrefix) {
                let fieldName = value.dropFirst(fieldPrefix.count)
                guard !fieldName.isEmpty else { return localized }
                return "\(localized)：\(fieldName)"
            }
            if let page = integer(
                in: value,
                prefix: "\(source) on page ",
                suffixes: [""]
            ) {
                return "\(localized)（第 \(page) 页）"
            }
        }
        return nil
    }

    private static func integer(
        in value: String,
        prefix: String,
        suffixes: [String]
    ) -> Int? {
        guard value.hasPrefix(prefix) else { return nil }
        for suffix in suffixes where value.hasSuffix(suffix) {
            let start = value.index(
                value.startIndex,
                offsetBy: prefix.count
            )
            let end = value.index(
                value.endIndex,
                offsetBy: -suffix.count
            )
            guard start <= end,
                  let number = Int(value[start..<end])
            else { continue }
            return number
        }
        return nil
    }

    private static func localizedClassificationSummary(
        _ value: String
    ) -> String? {
        let marker = " with "
        let ending = ". Review the evidence before acting."
        guard let markerRange = value.range(of: marker),
              value.hasSuffix(ending)
        else { return nil }
        let prefix = String(value[..<markerRange.lowerBound])
        let remainderStart = markerRange.upperBound
        let remainderEnd = value.index(
            value.endIndex,
            offsetBy: -ending.count
        )
        let remainder = String(
            value[remainderStart..<remainderEnd]
        )
        guard let count = integer(
            in: remainder,
            prefix: "",
            suffixes: [" detected fact", " detected facts"]
        ) else { return nil }

        let localizedPrefix: String
        if prefix.hasPrefix("Likely ") {
            let category = String(prefix.dropFirst("Likely ".count))
            localizedPrefix = "可能是\(category.capitalized.localizedUI)"
        } else if prefix.hasPrefix("Possible ") {
            let category = String(prefix.dropFirst("Possible ".count))
            localizedPrefix = "或许是\(category.capitalized.localizedUI)"
        } else {
            localizedPrefix = prefix.localizedUI
        }
        return "\(localizedPrefix)，检测到 \(count) 条信息。操作前请检查依据。"
    }

    private static func twoIntegers(
        in value: String,
        prefix: String,
        middle: String,
        suffix: String
    ) -> (first: Int, second: Int)? {
        guard value.hasPrefix(prefix),
              value.hasSuffix(suffix)
        else { return nil }
        let bodyStart = value.index(
            value.startIndex,
            offsetBy: prefix.count
        )
        let bodyEnd = value.index(
            value.endIndex,
            offsetBy: -suffix.count
        )
        let body = value[bodyStart..<bodyEnd]
        guard let middleRange = body.range(of: middle),
              let first = Int(body[..<middleRange.lowerBound]),
              let second = Int(body[middleRange.upperBound...])
        else { return nil }
        return (first, second)
    }
}

extension String {
    var localizedUI: String {
        AppLocalization.string(self)
    }
}
