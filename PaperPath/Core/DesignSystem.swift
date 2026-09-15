import CoreTransferable
import Darwin
import SwiftUI
import UniformTypeIdentifiers

enum AppBrand {
    static let name = "PaperPath"
    static let title = "PaperPath: Secure PDF Studio"
    static let subtitle = "Private PDFs. Verified output."
}

enum PPColor {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevated = Color(uiColor: .tertiarySystemGroupedBackground)
    static let surfaceMuted = Color(uiColor: .secondarySystemBackground)
    static let documentStage = Color("DocumentStage")
    static let border = Color(
        light: UIColor(red: 0.7, green: 0.735, blue: 0.76, alpha: 1),
        dark: UIColor(red: 0.23, green: 0.245, blue: 0.26, alpha: 1)
    )
    static let textPrimary = Color(
        light: UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.948, blue: 0.956, alpha: 1)
    )
    static let textSecondary = Color(
        light: UIColor(red: 0.315, green: 0.34, blue: 0.365, alpha: 1),
        dark: UIColor(red: 0.66, green: 0.68, blue: 0.7, alpha: 1)
    )
    static let onAccent = Color(
        light: .white,
        dark: UIColor(red: 0.035, green: 0.045, blue: 0.04, alpha: 1)
    )
    static let accent = Color(
        light: UIColor(red: 0.08, green: 0.28, blue: 0.5, alpha: 1),
        dark: UIColor(red: 0.31, green: 0.65, blue: 0.93, alpha: 1)
    )
    static let cyan = Color(
        light: UIColor(red: 0.08, green: 0.42, blue: 0.55, alpha: 1),
        dark: UIColor(red: 0.3, green: 0.72, blue: 0.8, alpha: 1)
    )
    static let mint = Color(
        light: UIColor(red: 0.12, green: 0.42, blue: 0.3, alpha: 1),
        dark: UIColor(red: 0.38, green: 0.78, blue: 0.58, alpha: 1)
    )
    static let amber = Color(
        light: UIColor(red: 0.68, green: 0.27, blue: 0.13, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.52, blue: 0.3, alpha: 1)
    )
    static let rose = Color(
        light: UIColor(red: 0.56, green: 0.16, blue: 0.25, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.43, blue: 0.55, alpha: 1)
    )
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

enum PPSpacing {
    static let hairline: CGFloat = 2
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let regular: CGFloat = 16
    static let large: CGFloat = 20
    static let xLarge: CGFloat = 24
    static let section: CGFloat = 32
}

enum PPMotion {
    static let press = Animation.easeOut(duration: 0.08)
    static let selection = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.15)
}

enum PPType {
    static let section = Font.headline
    static let document = Font.subheadline.weight(.semibold)
    static let metadata = Font.caption
    static let measure = Font.caption.monospacedDigit()
}

enum PPRadius {
    static let control: CGFloat = 7
    static let surface: CGFloat = 8
    static let document: CGFloat = 8
}

enum PPDeskLayout {
    static let maximumWidth: CGFloat = 1_440
    static let splitThreshold: CGFloat = 820
    static let inspectorWidth: CGFloat = 304
    static let previewWidth: CGFloat = 252
    static let rowPreviewWidth: CGFloat = 48
    static let touchTarget: CGFloat = 44
    static let sectionInset: CGFloat = 24
}

extension DynamicTypeSize {
    var ppPrefersExpandedLayout: Bool {
        self >= .xxLarge
    }
}

enum LocalFileSecurity {
    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    static func requireCompleteProtection(
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    static func prepareProtectedDirectory(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.complete
            ]
        )
        try requireCompleteProtection(
            to: url,
            fileManager: fileManager
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    static func isInsufficientStorageError(_ error: Error) -> Bool {
        var pending = [error as NSError]
        var inspectedCount = 0
        while let current = pending.popLast(),
              inspectedCount < 8 {
            inspectedCount += 1
            if current.domain == NSCocoaErrorDomain,
               current.code
                == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                return true
            }
            if current.domain == NSPOSIXErrorDomain,
               current.code == Int(ENOSPC) {
                return true
            }
            if let underlying = current.userInfo[
                NSUnderlyingErrorKey
            ] as? NSError {
                pending.append(underlying)
            }
            if let detailed = current.userInfo[
                "NSDetailedErrors"
            ] as? [NSError] {
                pending.append(contentsOf: detailed.prefix(4))
            }
        }
        return false
    }
}

final class ProtectedPhotoTransfer: Transferable, @unchecked Sendable {
    static let maximumEncodedByteCount: Int64 =
        64 * 1_024 * 1_024

    let fileURL: URL
    let byteCount: Int64

    private init(fileURL: URL, byteCount: Int64) {
        self.fileURL = fileURL
        self.byteCount = byteCount
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try await protectedCopy(of: received.file)
        }
    }

    deinit {
        discard()
    }

    func discard() {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .standardizedFileURL
        let candidate = fileURL.standardizedFileURL
        guard candidate.deletingLastPathComponent()
                == temporaryDirectory,
              PaperPathTemporaryArtifact.isManagedName(
                candidate.lastPathComponent
              )
        else { return }
        try? fileManager.removeItem(at: candidate)
    }

    private static func protectedCopy(
        of sourceURL: URL
    ) async throws -> ProtectedPhotoTransfer {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        let sourceValues = try sourceURL.resourceValues(
            forKeys: keys
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let sourceSize = sourceValues.fileSize,
              sourceSize > 0,
              Int64(sourceSize) <= maximumEncodedByteCount
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let destinationURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Photo-Transfer-\(UUID().uuidString).image"
            )
        guard !fileManager.fileExists(atPath: destinationURL.path),
              fileManager.createFile(
                atPath: destinationURL.path,
                contents: nil,
                attributes: [
                    .protectionKey: FileProtectionType.complete
                ]
              )
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        var preservesDestination = false
        defer {
            if !preservesDestination {
                try? fileManager.removeItem(at: destinationURL)
            }
        }

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }
        var copiedBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            let (nextByteCount, overflow) = copiedBytes
                .addingReportingOverflow(Int64(data.count))
            guard !overflow,
                  nextByteCount <= maximumEncodedByteCount,
                  nextByteCount <= Int64(sourceSize)
            else {
                throw CocoaError(.fileReadTooLarge)
            }
            try output.write(contentsOf: data)
            copiedBytes = nextByteCount
        }
        try Task.checkCancellation()
        try output.synchronize()
        let copiedValues = try destinationURL.resourceValues(
            forKeys: keys
        )
        guard copiedBytes == Int64(sourceSize),
              copiedValues.fileSize == sourceSize,
              copiedValues.isRegularFile == true,
              copiedValues.isSymbolicLink != true
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try LocalFileSecurity.requireCompleteProtection(
            to: destinationURL,
            fileManager: fileManager
        )
        LocalFileSecurity.excludeFromBackup(destinationURL)
        preservesDestination = true
        return ProtectedPhotoTransfer(
            fileURL: destinationURL,
            byteCount: copiedBytes
        )
    }
}

private final class PaperPathShareLeaseRegistry: @unchecked Sendable {
    static let shared = PaperPathShareLeaseRegistry()

    private let lock = NSLock()
    private var itemsByLeaseID: [UUID: Set<URL>] = [:]
    private var leaseCountByItem: [URL: Int] = [:]
    private var cleanupLeaseIDs: Set<UUID> = []
    private var pendingRemoval: Set<URL> = []

    private init() {}

    func begin(items: Set<URL>, removesItemsOnCompletion: Bool) -> UUID? {
        guard !items.isEmpty else { return nil }
        let leaseID = UUID()
        lock.lock()
        itemsByLeaseID[leaseID] = items
        if removesItemsOnCompletion {
            cleanupLeaseIDs.insert(leaseID)
        }
        for item in items {
            leaseCountByItem[item, default: 0] += 1
        }
        lock.unlock()
        return leaseID
    }

    func deferRemovalIfLeased(item: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard leaseCountByItem[item, default: 0] > 0 else {
            return false
        }
        pendingRemoval.insert(item)
        return true
    }

    func end(
        leaseID: UUID,
        forcesCleanup: Bool
    ) -> Set<URL> {
        lock.lock()
        defer { lock.unlock() }
        guard let items = itemsByLeaseID.removeValue(
            forKey: leaseID
        ) else { return [] }
        let cleansUp = cleanupLeaseIDs.remove(leaseID) != nil
        if cleansUp {
            pendingRemoval.formUnion(items)
        }

        var removableItems: Set<URL> = []
        for item in items {
            let remainingLeaseCount = max(
                0,
                leaseCountByItem[item, default: 1] - 1
            )
            if remainingLeaseCount == 0 {
                leaseCountByItem[item] = nil
                if pendingRemoval.remove(item) != nil {
                    removableItems.insert(item)
                }
            } else {
                leaseCountByItem[item] = remainingLeaseCount
                if forcesCleanup && cleansUp {
                    removableItems.insert(item)
                }
            }
        }
        return removableItems
    }
}

enum PaperPathTemporaryArtifact {
    static let officeSharePrefix =
        "PaperPath-Office-Share-"
    static let verifiedDeliveryPackagePrefix =
        "PaperPath-VerifiedDelivery-"
    static let verifiedOfficeDeliveryPrefix =
        "PaperPath-VerifiedOfficeDelivery-"
    static let verifiedVersionArchivePrefix =
        "PaperPath-VerifiedVersionArchive-"

    private struct UUIDNamePattern {
        let prefix: String
        let suffix: String
    }

    private static let maximumInterruptedScanCount = 1_024
    private static let maximumInterruptedCleanupCount = 256
    private static let uuidNamePatterns = [
        UUIDNamePattern(
            prefix: ".PaperPath-OOXML-",
            suffix: ".tmp"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Annotations-",
            suffix: ".md"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Annotations-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Attachments-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Bates-Prepared-",
            suffix: ".pdf"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Bates-Prepared-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Bates-Match-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Bates-Receipt-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Bates-Removal-Undo-",
            suffix: ".pdf"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Bates-Removal-Undo-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Bates-Removal-",
            suffix: ".pdf"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Bates-Removal-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Bates-Undo-",
            suffix: ".pdf"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Bates-Undo-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-ChangeReport-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-DeliveryPackage-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Delivery-Match-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-DeviceGoldenPath-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-DocumentExport-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Diagnostics-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-EmbeddedImages-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Evidence-",
            suffix: ".md"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Evidence-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-FilesExport-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Images-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Mutation-",
            suffix: ".pdf"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Mutation-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Office-Batch-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Office-Delivery-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Office-Export-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: officeSharePrefix,
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Office-Segment-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-PDFInspection-",
            suffix: ".pdf"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-PageUndo-",
            suffix: ".pdf"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-PageUndo-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Photo-Transfer-",
            suffix: ".image"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Replacement-",
            suffix: ".pdf"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Replacement-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Scan-",
            suffix: ".pdf"
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Signing-Identity-",
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Template-",
            suffix: ".pdf"
        ),
        UUIDNamePattern(
            prefix: verifiedDeliveryPackagePrefix,
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: verifiedOfficeDeliveryPrefix,
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: verifiedVersionArchivePrefix,
            suffix: ""
        ),
        UUIDNamePattern(
            prefix: "PaperPath-Version-Archive-",
            suffix: ""
        )
    ]
    private static let shortReportPatterns = [
        (
            prefix: "PaperPath-Bates-Match-",
            suffix: ".json"
        ),
        (
            prefix: "PaperPath-Bates-",
            suffix: ".json"
        ),
        (
            prefix: "PaperPath-Delivery-Match-",
            suffix: ".json"
        )
    ]

    static func isManagedName(_ name: String) -> Bool {
        for pattern in uuidNamePatterns {
            guard let identifier = identifier(
                in: name,
                prefix: pattern.prefix,
                suffix: pattern.suffix
            ) else { continue }
            if UUID(uuidString: identifier) != nil {
                return true
            }
        }
        for pattern in shortReportPatterns {
            guard let identifier = identifier(
                in: name,
                prefix: pattern.prefix,
                suffix: pattern.suffix
            ) else { continue }
            if isHexIdentifier(identifier, length: 8) {
                return true
            }
        }
        if isManagedPDFName(name) {
            return true
        }
        if let keyID = identifier(
            in: name,
            prefix: "PaperPath-Signing-Identity-",
            suffix: ".json"
        ) {
            return isHexIdentifier(keyID, length: 16)
        }
        return false
    }

    private static func isManagedPDFName(_ name: String) -> Bool {
        let suffix = ".pdf"
        guard name.hasPrefix("PaperPath-"),
              name.hasSuffix(suffix),
              name.count > "PaperPath--".count + 36
        else { return false }
        let stem = String(name.dropLast(suffix.count))
        let identifierStart = stem.index(
            stem.endIndex,
            offsetBy: -36
        )
        guard identifierStart > stem.startIndex else { return false }
        let separator = stem.index(before: identifierStart)
        guard stem[separator] == "-",
              UUID(uuidString: String(stem[identifierStart...])) != nil
        else { return false }
        let operation = String(stem[..<separator])
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-")
        )
        return operation.hasPrefix("PaperPath-")
            && operation.count > "PaperPath-".count
            && operation.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func managedTopLevelItem(
        containing candidate: URL,
        allowedPrefixes: [String]? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let temporaryRoot = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let standardized = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootComponents = temporaryRoot.pathComponents
        let candidateComponents = standardized.pathComponents
        guard standardized.isFileURL,
              candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count))
                == rootComponents
        else { return nil }

        let topLevelName = candidateComponents[rootComponents.count]
        guard isManagedName(topLevelName) else { return nil }
        if let allowedPrefixes,
           !allowedPrefixes.contains(where: {
               topLevelName.hasPrefix($0)
           }) {
            return nil
        }

        let topLevelURL = temporaryRoot
            .appendingPathComponent(topLevelName)
            .standardizedFileURL
        guard topLevelURL.deletingLastPathComponent()
                == temporaryRoot
        else { return nil }
        return topLevelURL
    }

    static func beginShareLease(
        for candidates: [URL],
        removesItemsOnCompletion: Bool = true,
        fileManager: FileManager = .default
    ) -> UUID? {
        let items = Set(candidates.compactMap {
            managedTopLevelItem(
                containing: $0,
                fileManager: fileManager
            )
        })
        return PaperPathShareLeaseRegistry.shared.begin(
            items: items,
            removesItemsOnCompletion: removesItemsOnCompletion
        )
    }

    static func endShareLease(
        _ leaseID: UUID,
        forcesCleanup: Bool = false,
        fileManager: FileManager = .default
    ) {
        let removableItems =
            PaperPathShareLeaseRegistry.shared.end(
                leaseID: leaseID,
                forcesCleanup: forcesCleanup
            )
        for item in removableItems {
            try? fileManager.removeItem(at: item)
        }
    }

    @discardableResult
    static func removeManagedItem(
        containing candidate: URL,
        allowedPrefixes: [String]? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let item = managedTopLevelItem(
            containing: candidate,
            allowedPrefixes: allowedPrefixes,
            fileManager: fileManager
        ) else { return false }
        // A share target may read the URL after PaperPath enters background.
        if PaperPathShareLeaseRegistry.shared
            .deferRemovalIfLeased(item: item) {
            return true
        }
        do {
            try fileManager.removeItem(at: item)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func discardInterruptedItems(
        fileManager: FileManager = .default
    ) throws -> Int {
        let temporaryRoot = fileManager.temporaryDirectory
            .standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: temporaryRoot,
            includingPropertiesForKeys: nil,
            options: [
                .skipsSubdirectoryDescendants,
                .skipsPackageDescendants
            ]
        ) else { return 0 }

        var inspectedCount = 0
        var removedCount = 0
        while let candidate = enumerator.nextObject() as? URL,
              inspectedCount < maximumInterruptedScanCount,
              removedCount < maximumInterruptedCleanupCount {
            try Task.checkCancellation()
            inspectedCount += 1
            guard let item = managedTopLevelItem(
                containing: candidate,
                fileManager: fileManager
            ) else { continue }
            if removeManagedItem(
                containing: item,
                fileManager: fileManager
            ) {
                removedCount += 1
            }
        }
        return removedCount
    }

    private static func identifier(
        in name: String,
        prefix: String,
        suffix: String
    ) -> String? {
        guard name.hasPrefix(prefix),
              name.hasSuffix(suffix),
              name.count > prefix.count + suffix.count
        else { return nil }
        let start = name.index(
            name.startIndex,
            offsetBy: prefix.count
        )
        let end = name.index(
            name.endIndex,
            offsetBy: -suffix.count
        )
        guard start < end else { return nil }
        return String(name[start..<end])
    }

    private static func isHexIdentifier(
        _ value: String,
        length: Int
    ) -> Bool {
        let hexadecimalScalars = Set(
            "0123456789abcdefABCDEF".unicodeScalars
        )
        return value.count == length
            && value.unicodeScalars.allSatisfy {
                hexadecimalScalars.contains($0)
            }
    }
}

struct PPCanvas: View {
    var body: some View {
        PPColor.canvas
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

struct StudioPaperGrid: View {
    let lineOpacity: Double

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            let baseline: CGFloat = 44
            var rules = Path()
            var y = baseline
            while y < size.height {
                rules.move(to: CGPoint(x: 0, y: y))
                rules.addLine(to: CGPoint(x: size.width, y: y))
                y += baseline
            }
            context.stroke(
                rules,
                with: .color(PPColor.border.opacity(lineOpacity)),
                lineWidth: 0.35
            )

            let marginX = min(max(size.width * 0.055, 20), 54)
            var margin = Path()
            margin.move(to: CGPoint(x: marginX, y: 0))
            margin.addLine(to: CGPoint(x: marginX, y: size.height))
            context.stroke(
                margin,
                with: .color(PPColor.rose.opacity(lineOpacity * 0.85)),
                lineWidth: 0.45
            )

            for point in [
                CGPoint(x: marginX, y: baseline),
                CGPoint(x: size.width - marginX, y: baseline)
            ] {
                let rect = CGRect(
                    x: point.x - 3,
                    y: point.y - 3,
                    width: 6,
                    height: 6
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(
                        PPColor.textSecondary.opacity(lineOpacity)
                    ),
                    lineWidth: 0.45
                )
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct PaperGrain: View {
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            for index in 0..<32 {
                let seed = Double(index + 1)
                let x = CGFloat(
                    abs(sin(seed * 12.9898)) * Double(size.width)
                )
                let y = CGFloat(
                    abs(sin(seed * 78.233)) * Double(size.height)
                )
                let length = CGFloat(5 + Int(seed * 17) % 18)
                let angle = CGFloat(sin(seed * 4.13)) * 0.18
                var fiber = Path()
                fiber.move(to: CGPoint(x: x, y: y))
                fiber.addLine(
                    to: CGPoint(
                        x: x + cos(angle) * length,
                        y: y + sin(angle) * length
                    )
                )
                context.stroke(
                    fiber,
                    with: .color(PPColor.textPrimary.opacity(opacity)),
                    lineWidth: index.isMultiple(of: 5) ? 0.45 : 0.25
                )
            }
        }
        .blendMode(.softLight)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct PPCardModifier: ViewModifier {
    var padding: CGFloat = PPSpacing.regular
    var emphasized = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.surface,
                    bottomTrailingRadius: PPRadius.surface,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                    .fill(emphasized ? PPColor.elevated : PPColor.surface)
            }
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.surface,
                    bottomTrailingRadius: PPRadius.surface,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                    .stroke(
                        emphasized
                            ? PPColor.accent.opacity(0.28)
                            : PPColor.border.opacity(0.66),
                        lineWidth: 0.6
                    )
            }
            .shadow(
                color: emphasized ? .black.opacity(0.08) : .clear,
                radius: emphasized ? 6 : 0,
                y: emphasized ? 2 : 0
            )
    }
}

struct PPPaperSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = PPRadius.surface
    var shadow = true

    func body(content: Content) -> some View {
        content
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: cornerRadius,
                    bottomTrailingRadius: cornerRadius,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                .fill(PPColor.surface)
            }
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: cornerRadius,
                    bottomTrailingRadius: cornerRadius,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                .stroke(PPColor.border.opacity(0.48), lineWidth: 0.55)
            }
            .shadow(
                color: shadow ? .black.opacity(0.08) : .clear,
                radius: shadow ? 6 : 0,
                y: shadow ? 3 : 0
            )
    }
}

struct PPRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .onAppear {
                guard !visible else { return }
                if reduceMotion {
                    visible = true
                } else {
                    withAnimation(
                        .spring(response: 0.5, dampingFraction: 0.88)
                            .delay(delay)
                    ) {
                        visible = true
                    }
                }
            }
    }
}

extension View {
    func ppCard(
        padding: CGFloat = PPSpacing.regular,
        emphasized: Bool = false
    ) -> some View {
        modifier(PPCardModifier(padding: padding, emphasized: emphasized))
    }

    func ppReveal(delay: Double = 0) -> some View {
        modifier(PPRevealModifier(delay: delay))
    }

    func ppPaper(
        cornerRadius: CGFloat = PPRadius.surface,
        shadow: Bool = true
    ) -> some View {
        modifier(
            PPPaperSurfaceModifier(
                cornerRadius: cornerRadius,
                shadow: shadow
            )
        )
    }

    func ppCanvas() -> some View {
        background { PPCanvas() }
    }
}

struct PPPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(PPColor.onAccent)
            .multilineTextAlignment(.center)
            .padding(.horizontal, PPSpacing.regular)
            .padding(.vertical, PPSpacing.small)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(PPColor.accent.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.control,
                    bottomTrailingRadius: PPRadius.control,
                    topTrailingRadius: 2,
                    style: .continuous
                )
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.control,
                    bottomTrailingRadius: PPRadius.control,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                    .stroke(PPColor.onAccent.opacity(0.14), lineWidth: 0.6)
            }
            .scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.985 : 1
            )
            .opacity(isEnabled ? 1 : 0.42)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: configuration.isPressed
            )
            .hoverEffect(.highlight)
    }
}

struct PPQuietButtonStyle: ButtonStyle {
    var tint: Color = PPColor.textPrimary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, PPSpacing.regular)
            .frame(minHeight: 44)
            .background(
                PPColor.elevated.opacity(configuration.isPressed ? 0.72 : 1)
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.control,
                    bottomTrailingRadius: PPRadius.control,
                    topTrailingRadius: 2,
                    style: .continuous
                )
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.control,
                    bottomTrailingRadius: PPRadius.control,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                    .stroke(PPColor.border.opacity(0.68), lineWidth: 0.6)
            }
            .scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.98 : 1
            )
            .opacity(isEnabled ? 1 : 0.42)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
            .hoverEffect(.highlight)
    }
}

struct OnDeviceBadge: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var compact = false

    var body: some View {
        HStack(spacing: compact ? 5 : PPSpacing.small) {
            Image(systemName: "iphone")
                .font(
                    compact
                        ? .caption2.weight(.bold)
                        : .caption.weight(.bold)
                )
                .dynamicTypeSize(.xSmall ... .accessibility1)
                .foregroundStyle(PPColor.mint)
                .frame(
                    width: compact ? 18 : 27,
                    height: compact ? 18 : 27
                )
                .background(
                    Circle()
                        .fill(PPColor.mint.opacity(0.1))
                )
                .overlay {
                    Circle()
                        .stroke(
                            PPColor.mint.opacity(0.54),
                            lineWidth: 0.8
                        )
                }

            if compact {
                Text("ON DEVICE".localizedUI)
                    .font(.caption2.smallCaps().weight(.semibold))
                    .foregroundStyle(PPColor.mint)
                    .lineLimit(
                        dynamicTypeSize.isAccessibilitySize ? 2 : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ON DEVICE".localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                    Text("Private workspace".localizedUI)
                        .font(.caption2)
                }
                .foregroundStyle(PPColor.textSecondary)
            }
        }
        .padding(.horizontal, compact ? 7 : 0)
        .padding(.vertical, compact ? 4 : 0)
        .background {
            if compact {
                Capsule()
                    .fill(PPColor.mint.opacity(0.09))
            }
        }
        .overlay {
            if compact {
                Capsule()
                    .stroke(PPColor.mint.opacity(0.38), lineWidth: 0.7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Processing stays on this device".localizedUI)
    }
}
