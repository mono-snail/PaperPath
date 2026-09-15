import CryptoKit
import Foundation
import ImageIO

struct SavedSignature: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var data: Data

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        data: Data
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.data = data
    }
}

struct SavedSignatureLibrary: Codable, Equatable, Sendable {
    var selectedID: UUID?
    var entries: [SavedSignature]

    static let empty = SavedSignatureLibrary(
        selectedID: nil,
        entries: []
    )
}

actor SignatureStore {
    static let maximumSignatureCount = 5
    private static let maximumSignatureBytes = 5 * 1_024 * 1_024
    private static let maximumLibraryBytes = 40 * 1_024 * 1_024
    private static let maximumSignatureDimension = 4_096
    private static let maximumSignaturePixels = 16_000_000

    private let legacyFileURL: URL
    private let libraryFileURL: URL
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let directory = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("PaperPath", isDirectory: true)
        legacyFileURL = directory.appendingPathComponent(
            "saved-signature.data"
        )
        libraryFileURL = directory.appendingPathComponent(
            "saved-signatures.json"
        )
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() throws -> Data? {
        let library = try loadLibrary()
        return selectedEntry(in: library)?.data
    }

    func loadLibrary() throws -> SavedSignatureLibrary {
        if fileManager.fileExists(atPath: libraryFileURL.path) {
            let data = try protectedBoundedData(
                at: libraryFileURL,
                maximumBytes: Self.maximumLibraryBytes
            )
            let library: SavedSignatureLibrary
            do {
                library = try decoder.decode(
                    SavedSignatureLibrary.self,
                    from: data
                )
            } catch {
                throw PaperPathError.storageFailure(
                    "The saved signature library is unreadable."
                )
            }
            let repaired = normalized(library)
            if repaired != library {
                try saveLibrary(repaired)
            }
            return repaired
        }

        guard fileManager.fileExists(atPath: legacyFileURL.path) else {
            return .empty
        }
        let legacyData = try protectedBoundedData(
            at: legacyFileURL,
            maximumBytes: Self.maximumSignatureBytes
        )
        guard isValidSignatureData(legacyData) else {
            throw PaperPathError.storageFailure(
                "The saved signature is unreadable."
            )
        }

        let entry = SavedSignature(data: legacyData)
        let migrated = SavedSignatureLibrary(
            selectedID: entry.id,
            entries: [entry]
        )
        try saveLibrary(migrated)
        return migrated
    }

    @discardableResult
    func add(_ data: Data) throws -> SavedSignatureLibrary {
        try validate(data)
        var library = try loadLibrary()
        if let existingIndex = library.entries.firstIndex(
            where: { $0.data == data }
        ) {
            library.entries[existingIndex].updatedAt = Date()
            let entry = library.entries.remove(at: existingIndex)
            library.entries.insert(entry, at: 0)
            library.selectedID = entry.id
        } else {
            let entry = SavedSignature(data: data)
            library.entries.insert(entry, at: 0)
            library.selectedID = entry.id
        }
        library.entries = Array(
            library.entries.prefix(Self.maximumSignatureCount)
        )
        try saveLibrary(library)
        return normalized(library)
    }

    @discardableResult
    func select(_ id: UUID) throws -> SavedSignatureLibrary {
        var library = try loadLibrary()
        guard library.entries.contains(where: { $0.id == id }) else {
            return normalized(library)
        }
        library.selectedID = id
        try saveLibrary(library)
        return normalized(library)
    }

    @discardableResult
    func remove(id: UUID) throws -> SavedSignatureLibrary {
        var library = try loadLibrary()
        library.entries.removeAll { $0.id == id }
        if library.selectedID == id {
            library.selectedID = library.entries.first?.id
        }
        try saveLibrary(library)
        return normalized(library)
    }

    func save(_ data: Data) throws {
        _ = try add(data)
    }

    func remove() throws {
        for url in [libraryFileURL, legacyFileURL] where
            fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func saveLibrary(_ library: SavedSignatureLibrary) throws {
        for entry in library.entries {
            try validate(entry.data)
        }
        let normalizedLibrary = normalized(library)
        let directory = libraryFileURL.deletingLastPathComponent()
        try LocalFileSecurity.prepareProtectedDirectory(
            at: directory,
            fileManager: fileManager
        )
        let data = try encoder.encode(normalizedLibrary)
        guard data.count <= Self.maximumLibraryBytes else {
            throw PaperPathError.storageFailure(
                "The saved signature library exceeds its safe storage limit."
            )
        }
        let stagingURL = directory.appendingPathComponent(
            ".saved-signatures-\(UUID().uuidString).json"
        )
        let backupName =
            ".saved-signatures-backup-\(UUID().uuidString).json"
        let backupURL = directory.appendingPathComponent(backupName)
        var shouldRemoveBackup = true
        defer {
            try? fileManager.removeItem(at: stagingURL)
            if shouldRemoveBackup {
                try? fileManager.removeItem(at: backupURL)
            }
        }
        let expectedFingerprint = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        try data.write(
            to: stagingURL,
            options: [.atomic, .completeFileProtection]
        )
        try LocalFileSecurity.requireCompleteProtection(
            to: stagingURL,
            fileManager: fileManager
        )
        guard try fileFingerprint(
            at: stagingURL,
            expectedByteCount: data.count
        ) == expectedFingerprint else {
            throw PaperPathError.storageFailure(
                "A protected staging file could not be verified."
            )
        }
        if fileManager.fileExists(atPath: libraryFileURL.path) {
            let previousValues = try libraryFileURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard previousValues.isRegularFile == true,
                  previousValues.isSymbolicLink != true,
                  let previousByteCount = previousValues.fileSize,
                  previousByteCount > 0,
                  previousByteCount <= Self.maximumLibraryBytes
            else {
                throw PaperPathError.storageFailure(
                    "The saved signature library is unreadable."
                )
            }
            let previousFingerprint = try fileFingerprint(
                at: libraryFileURL,
                expectedByteCount: previousByteCount
            )
            var replacementStarted = false
            do {
                replacementStarted = true
                _ = try fileManager.replaceItemAt(
                    libraryFileURL,
                    withItemAt: stagingURL,
                    backupItemName: backupName,
                    options: [.withoutDeletingBackupItem]
                )
                try verifyPublishedLibrary(
                    expectedByteCount: data.count,
                    expectedFingerprint: expectedFingerprint
                )
            } catch {
                guard replacementStarted,
                      fileManager.fileExists(atPath: backupURL.path)
                else { throw error }
                do {
                    if fileManager.fileExists(
                        atPath: libraryFileURL.path
                    ) {
                        _ = try fileManager.replaceItemAt(
                            libraryFileURL,
                            withItemAt: backupURL
                        )
                    } else {
                        try fileManager.moveItem(
                            at: backupURL,
                            to: libraryFileURL
                        )
                    }
                    try LocalFileSecurity.requireCompleteProtection(
                        to: libraryFileURL,
                        fileManager: fileManager
                    )
                    guard try fileFingerprint(
                        at: libraryFileURL,
                        expectedByteCount: previousByteCount
                    ) == previousFingerprint else {
                        throw PaperPathError.storageFailure(
                            "The previous saved signature library could not be restored."
                        )
                    }
                } catch {
                    shouldRemoveBackup = false
                    try? LocalFileSecurity.requireCompleteProtection(
                        to: backupURL,
                        fileManager: fileManager
                    )
                    throw PaperPathError.storageFailure(
                        "The previous saved signature library could not be restored."
                    )
                }
                throw error
            }
        } else {
            var didPublish = false
            do {
                try fileManager.moveItem(
                    at: stagingURL,
                    to: libraryFileURL
                )
                didPublish = true
                try verifyPublishedLibrary(
                    expectedByteCount: data.count,
                    expectedFingerprint: expectedFingerprint
                )
            } catch {
                if didPublish,
                   fileManager.fileExists(atPath: libraryFileURL.path) {
                    try? fileManager.removeItem(at: libraryFileURL)
                }
                throw error
            }
        }
        if fileManager.fileExists(atPath: legacyFileURL.path) {
            try? fileManager.removeItem(at: legacyFileURL)
        }
    }

    private func verifyPublishedLibrary(
        expectedByteCount: Int,
        expectedFingerprint: String
    ) throws {
        try LocalFileSecurity.requireCompleteProtection(
            to: libraryFileURL,
            fileManager: fileManager
        )
        guard try fileFingerprint(
            at: libraryFileURL,
            expectedByteCount: expectedByteCount
        ) == expectedFingerprint else {
            throw PaperPathError.storageFailure(
                "A protected file changed while it was published."
            )
        }
    }

    private func normalized(
        _ library: SavedSignatureLibrary
    ) -> SavedSignatureLibrary {
        var entries = Array(
            library.entries
                .filter {
                    isValidSignatureData($0.data)
                }
        )
        var seen: Set<UUID> = []
        var seenData = Set<Data>()
        entries.removeAll { entry in
            if seen.contains(entry.id)
                || seenData.contains(entry.data) {
                return true
            }
            seen.insert(entry.id)
            seenData.insert(entry.data)
            return false
        }
        entries = Array(entries.prefix(Self.maximumSignatureCount))
        let selectedID = entries.contains { $0.id == library.selectedID }
            ? library.selectedID
            : entries.first?.id
        return SavedSignatureLibrary(
            selectedID: selectedID,
            entries: entries
        )
    }

    private func selectedEntry(
        in library: SavedSignatureLibrary
    ) -> SavedSignature? {
        guard let selectedID = library.selectedID else {
            return library.entries.first
        }
        return library.entries.first { $0.id == selectedID }
            ?? library.entries.first
    }

    private func validate(_ data: Data) throws {
        guard !data.isEmpty else {
            throw PaperPathError.storageFailure(
                "The saved signature is empty."
            )
        }
        guard data.count <= Self.maximumSignatureBytes else {
            throw PaperPathError.storageFailure(
                "The saved signature is too complex."
            )
        }
        guard isValidSignatureData(data) else {
            throw PaperPathError.storageFailure(
                "The saved signature image is invalid or too large."
            )
        }
    }

    private func isValidSignatureData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= Self.maximumSignatureBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  nil
              ),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth]
                as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight]
                as? NSNumber
        else { return false }
        let widthValue = width.intValue
        let heightValue = height.intValue
        guard widthValue > 0,
              heightValue > 0,
              widthValue <= Self.maximumSignatureDimension,
              heightValue <= Self.maximumSignatureDimension
        else { return false }
        let (pixels, overflow) = widthValue.multipliedReportingOverflow(
            by: heightValue
        )
        return !overflow && pixels <= Self.maximumSignaturePixels
    }

    private func protectedBoundedData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        try LocalFileSecurity.requireCompleteProtection(
            to: url,
            fileManager: fileManager
        )
        return try boundedData(
            at: url,
            maximumBytes: maximumBytes
        )
    }

    func boundedData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes >= 0,
              maximumBytes < Int.max
        else {
            throw PaperPathError.storageFailure(
                "The signature read limit is invalid."
            )
        }
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount >= 0,
              byteCount <= maximumBytes
        else {
            throw PaperPathError.storageFailure(
                "The saved signature library exceeds its safe read limit."
            )
        }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(byteCount)
        while data.count < byteCount {
            try Task.checkCancellation()
            let requestedByteCount = min(
                1_048_576,
                byteCount - data.count
            )
            let chunk = try handle.read(
                upToCount: requestedByteCount
            ) ?? Data()
            guard !chunk.isEmpty else {
                throw PaperPathError.storageFailure(
                    "A local metadata file changed while it was read."
                )
            }
            data.append(chunk)
        }
        let trailingByte = try handle.read(upToCount: 1) ?? Data()
        guard trailingByte.isEmpty,
              data.count == byteCount,
              data.count <= maximumBytes
        else {
            throw PaperPathError.storageFailure(
                "A local metadata file changed while it was read."
            )
        }
        try requireUnchangedFile(
            at: url,
            initialValues: values,
            expectedByteCount: byteCount
        )
        try Task.checkCancellation()
        return data
    }

    private func fileFingerprint(
        at url: URL,
        expectedByteCount: Int
    ) throws -> String {
        guard expectedByteCount >= 0,
              expectedByteCount <= Self.maximumLibraryBytes
        else {
            throw PaperPathError.storageFailure(
                "The saved signature library exceeds its safe read limit."
            )
        }
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == expectedByteCount
        else {
            throw PaperPathError.storageFailure(
                "A protected staging file could not be verified."
            )
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var processedByteCount = 0
        while processedByteCount < expectedByteCount {
            try Task.checkCancellation()
            let requestedByteCount = min(
                1_048_576,
                expectedByteCount - processedByteCount
            )
            let chunk = try handle.read(
                upToCount: requestedByteCount
            ) ?? Data()
            guard !chunk.isEmpty else {
                throw PaperPathError.storageFailure(
                    "A local metadata file changed while it was read."
                )
            }
            hasher.update(data: chunk)
            processedByteCount += chunk.count
        }
        let trailingByte = try handle.read(upToCount: 1) ?? Data()
        guard trailingByte.isEmpty,
              processedByteCount == expectedByteCount
        else {
            throw PaperPathError.storageFailure(
                "A local metadata file changed while it was read."
            )
        }
        try requireUnchangedFile(
            at: url,
            initialValues: values,
            expectedByteCount: expectedByteCount
        )
        try Task.checkCancellation()
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func requireUnchangedFile(
        at url: URL,
        initialValues: URLResourceValues,
        expectedByteCount: Int
    ) throws {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let finalValues = try freshURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard finalValues.isRegularFile == true,
              finalValues.isSymbolicLink != true,
              finalValues.fileSize == expectedByteCount,
              finalValues.contentModificationDate
                == initialValues.contentModificationDate,
              fileResourceIdentifiersMatch(
                  initialValues.fileResourceIdentifier,
                  finalValues.fileResourceIdentifier
              )
        else {
            throw PaperPathError.storageFailure(
                "A local metadata file changed while it was read."
            )
        }
    }

    private func fileResourceIdentifiersMatch(
        _ first: Any?,
        _ second: Any?
    ) -> Bool {
        switch (first, second) {
        case (nil, nil):
            return true
        case let (first as NSObject, second):
            return first.isEqual(second)
        default:
            return false
        }
    }
}
