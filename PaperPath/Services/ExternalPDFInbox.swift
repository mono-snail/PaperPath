import CryptoKit
import Darwin
import Foundation

struct ExternalPDFInboxItem: Sendable {
    let id: UUID
    let containerURL: URL
    let fileURL: URL
    let preferredName: String
    let receivedAt: Date
    let expectedSHA256: String
    let byteCount: Int64

    init(
        id: UUID = UUID(),
        containerURL: URL,
        fileURL: URL,
        preferredName: String,
        receivedAt: Date = .distantPast,
        expectedSHA256: String = "",
        byteCount: Int64 = 0
    ) {
        self.id = id
        self.containerURL = containerURL
        self.fileURL = fileURL
        self.preferredName = preferredName
        self.receivedAt = receivedAt
        self.expectedSHA256 = expectedSHA256
        self.byteCount = byteCount
    }

}

struct ExternalPDFInboxSnapshot: Sendable {
    let items: [ExternalPDFInboxItem]
    let discardedInvalidItemCount: Int
    var deferredItems: [ExternalPDFInboxDeferredItem] = []
}

struct ExternalPDFInboxDeferredItem: Sendable {
    let containerURL: URL
    let reason: ExternalPDFInboxError
}

final class ExternalPDFInboxCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            throw CancellationError()
        }
    }
}

enum ExternalPDFInboxError: LocalizedError, Sendable {
    case sharedContainerUnavailable
    case invalidPDF
    case fileTooLarge
    case inboxFull
    case insufficientStorage
    case incompleteCopy
    case invalidReceiveDate
    case temporarilyUnavailable

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            return ExternalPDFInbox.localized(
                "PaperPath shared storage is unavailable."
            )
        case .invalidPDF:
            return ExternalPDFInbox.localized(
                "That item is not a readable PDF."
            )
        case .fileTooLarge:
            return ExternalPDFInbox.localized(
                "Shared PDFs must be 1 GB or smaller."
            )
        case .inboxFull:
            return ExternalPDFInbox.localized(
                "Shared import queue is full. Finish pending imports, then retry."
            )
        case .insufficientStorage:
            return ExternalPDFInbox.localized(
                "There isn’t enough free space to prepare this PDF."
            )
        case .incompleteCopy:
            return ExternalPDFInbox.localized(
                "The private PDF copy could not be verified."
            )
        case .invalidReceiveDate:
            return ExternalPDFInbox.localized(
                "A queued PDF has an unexpected receive date. Check the device date and retry."
            )
        case .temporarilyUnavailable:
            return ExternalPDFInbox.localized(
                "A queued PDF is temporarily unavailable. Its private copy has been kept for retry."
            )
        }
    }
}

enum ExternalPDFInbox {
    static let appGroupIdentifier = "group.com.monoware.paperpath"

    private struct Metadata: Codable {
        let preferredName: String
        let receivedAt: Date
        let payloadSHA256: String?
        let payloadByteCount: Int64?

        init(
            preferredName: String,
            receivedAt: Date,
            payloadSHA256: String?,
            payloadByteCount: Int64?
        ) {
            self.preferredName = preferredName
            self.receivedAt = receivedAt
            self.payloadSHA256 = payloadSHA256
            self.payloadByteCount = payloadByteCount
        }
    }

    private static let rootDirectoryName = "SharedImports"
    private static let inboxDirectoryName = "Inbox"
    private static let stagingDirectoryName = "Staging"
    private static let payloadFileName = "document.pdf"
    private static let metadataFileName = "metadata.json"
    private static let metadataStagingPrefix = ".metadata-"
    private static let metadataRollbackPrefix = ".metadata-rollback-"
    private static let consumedContainerPrefix = ".consumed-"
    private static let processingContainerPrefix = ".processing-"
    private static let stagingRetention: TimeInterval = 24 * 60 * 60
    private static let maximumPayloadBytes: Int64 =
        1_024 * 1_024 * 1_024
    private static let maximumPendingPayloadBytes: Int64 =
        4 * 1_024 * 1_024 * 1_024
    private static let maximumPendingItemCount = 64
    private static let maximumDirectoryEntriesToInspect = 1_024
    private static let maximumCleanupItemsPerPass = 256
    private static let maximumMetadataBytes = 64 * 1_024
    private static let stagingLock = NSLock()

    static func stagePDF(
        from sourceURL: URL,
        suggestedName: String? = nil,
        sharedContainerURL: URL? = nil,
        protectionHandler: (URL) throws -> Void = {
            try requireCompleteProtection(at: $0)
        },
        progress: @Sendable (Int64, Int64) -> Void = { _, _ in },
        cancellationCheck: () throws -> Void = {
            try Task.checkCancellation()
        }
    ) throws -> ExternalPDFInboxItem {
        try cancellationCheck()
        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        while !stagingLock.lock(
            before: Date(timeIntervalSinceNow: 0.1)
        ) {
            try cancellationCheck()
        }
        defer { stagingLock.unlock() }
        try cancellationCheck()

        let sourceValues = try sourceURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let sourceSize = sourceValues.fileSize,
              sourceSize > 0
        else {
            throw ExternalPDFInboxError.invalidPDF
        }
        guard Int64(sourceSize) <= maximumPayloadBytes else {
            throw ExternalPDFInboxError.fileTooLarge
        }
        try cancellationCheck()
        guard try hasPDFHeader(at: sourceURL) else {
            throw ExternalPDFInboxError.invalidPDF
        }

        let directories = try importDirectories(
            sharedContainerURL: sharedContainerURL,
            protectionHandler: protectionHandler
        )
        let pendingUsage = try pendingPayloadUsage(
            in: directories.inbox
        )
        let (queuedBytes, overflow) = pendingUsage.bytes
            .addingReportingOverflow(Int64(sourceSize))
        guard pendingUsage.count < maximumPendingItemCount,
              !overflow,
              queuedBytes <= maximumPendingPayloadBytes
        else {
            throw ExternalPDFInboxError.inboxFull
        }
        try ensureCapacity(
            sourceBytes: Int64(sourceSize),
            in: directories.staging
        )
        let itemID = UUID()
        let identifier = itemID.uuidString
        let stagingURL = directories.staging
            .appendingPathComponent(identifier, isDirectory: true)
        let destinationURL = directories.inbox
            .appendingPathComponent("\(identifier).inbox", isDirectory: true)

        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false
        )

        do {
            try protectionHandler(stagingURL)
            try cancellationCheck()
            let payloadURL = stagingURL.appendingPathComponent(payloadFileName)
            let copiedPayload = try copyPayload(
                from: sourceURL,
                to: payloadURL,
                expectedByteCount: Int64(sourceSize),
                protectionHandler: protectionHandler,
                progress: progress,
                cancellationCheck: cancellationCheck
            )
            let copiedValues = try payloadURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard copiedValues.isRegularFile == true,
                  copiedValues.isSymbolicLink != true,
                  copiedValues.fileSize == sourceSize,
                  copiedPayload.byteCount == Int64(sourceSize),
                  copiedPayload.hasPDFHeader
            else {
                throw ExternalPDFInboxError.incompleteCopy
            }
            let payloadSHA256 = copiedPayload.sha256

            let preferredName = normalizedName(
                suggestedName ?? sourceURL.lastPathComponent
            )
            let receivedAt = Date()
            let metadata = Metadata(
                preferredName: preferredName,
                receivedAt: receivedAt,
                payloadSHA256: payloadSHA256,
                payloadByteCount: Int64(sourceSize)
            )
            try writeMetadata(
                metadata,
                to: stagingURL.appendingPathComponent(metadataFileName),
                protectionHandler: protectionHandler
            )
            try cancellationCheck()

            let committedUsage = try pendingPayloadUsage(
                in: directories.inbox
            )
            let (committedBytes, committedOverflow) =
                committedUsage.bytes.addingReportingOverflow(
                    Int64(sourceSize)
                )
            guard committedUsage.count < maximumPendingItemCount,
                  !committedOverflow,
                  committedBytes <= maximumPendingPayloadBytes
            else {
                throw ExternalPDFInboxError.inboxFull
            }
            try FileManager.default.moveItem(
                at: stagingURL,
                to: destinationURL
            )
            let committedItem = ExternalPDFInboxItem(
                id: itemID,
                containerURL: destinationURL,
                fileURL: destinationURL
                    .appendingPathComponent(payloadFileName),
                preferredName: preferredName,
                receivedAt: receivedAt,
                expectedSHA256: payloadSHA256,
                byteCount: Int64(sourceSize)
            )
            guard try metadataMatches(committedItem, in: destinationURL) else {
                throw ExternalPDFInboxError.incompleteCopy
            }
            try protectionHandler(destinationURL)
            excludeFromBackup(destinationURL)
            return committedItem
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    static func pendingItems(
        sharedContainerURL: URL? = nil
    ) throws -> [ExternalPDFInboxItem] {
        try pendingSnapshot(
            sharedContainerURL: sharedContainerURL
        ).items
    }

    static func pendingSnapshot(
        sharedContainerURL: URL? = nil,
        excludingContainers: Set<URL> = []
    ) throws -> ExternalPDFInboxSnapshot {
        try Task.checkCancellation()
        let directories = try importDirectories(
            sharedContainerURL: sharedContainerURL
        )
        var deferredItems: [ExternalPDFInboxDeferredItem] = []
        var discardedInvalidItemCount = try recoverInterruptedClaims(
            in: directories.inbox,
            excludingContainers: excludingContainers,
            deferredItems: &deferredItems
        )
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .creationDateKey
        ]
        let scan = try boundedDirectoryContents(
            at: directories.inbox,
            includingPropertiesForKeys: Array(keys),
            skipsHiddenFiles: true
        )
        guard !scan.isTruncated else {
            throw ExternalPDFInboxError.inboxFull
        }
        var items: [ExternalPDFInboxItem] = []
        items.reserveCapacity(min(scan.urls.count, maximumPendingItemCount))
        for url in scan.urls
        where url.pathExtension == "inbox"
            && !excludingContainers.contains(url) {
            try Task.checkCancellation()
            do {
                if let item = try pendingItem(
                    in: url,
                    inboxURL: directories.inbox
                ) {
                    items.append(item)
                } else {
                    try FileManager.default.removeItem(at: url)
                    discardedInvalidItemCount += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                deferredItems.append(
                    ExternalPDFInboxDeferredItem(
                        containerURL: url,
                        reason: retryReason(for: error)
                    )
                )
            }
        }
        items.sort {
            if $0.receivedAt == $1.receivedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.receivedAt < $1.receivedAt
        }
        return ExternalPDFInboxSnapshot(
            items: items,
            discardedInvalidItemCount: discardedInvalidItemCount,
            deferredItems: deferredItems.sorted {
                $0.containerURL.lastPathComponent
                    < $1.containerURL.lastPathComponent
            }
        )
    }

    private static func pendingItem(
        in containerURL: URL,
        inboxURL: URL
    ) throws -> ExternalPDFInboxItem? {
        guard let itemID = UUID(
            uuidString: containerURL.deletingPathExtension().lastPathComponent
        ),
              try isValidContainer(containerURL, in: inboxURL)
        else { return nil }
        let fileURL = containerURL.appendingPathComponent(payloadFileName)
        let values = try resourceValuesIfPresent(
            at: fileURL,
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              let fileSize = values?.fileSize,
              fileSize > 0,
              Int64(fileSize) <= maximumPayloadBytes,
              try hasPDFHeader(at: fileURL)
        else { return nil }

        let metadataURL = containerURL.appendingPathComponent(metadataFileName)
        try requireCompleteProtection(at: fileURL)
        let metadata: Metadata
        if let savedMetadata = try readMetadata(at: metadataURL) {
            try requireCompleteProtection(at: metadataURL)
            metadata = savedMetadata
        } else {
            let creationDate = try containerURL.resourceValues(
                forKeys: [.creationDateKey]
            ).creationDate ?? .distantPast
            let repaired = Metadata(
                preferredName: "Shared PDF",
                receivedAt: isValidReceivedAt(creationDate) ? creationDate : Date(),
                payloadSHA256: try fileFingerprint(at: fileURL),
                payloadByteCount: Int64(fileSize)
            )
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                try FileManager.default.removeItem(at: metadataURL)
            }
            try writeMetadata(
                repaired,
                to: metadataURL,
                protectionHandler: { try requireCompleteProtection(at: $0) }
            )
            metadata = repaired
        }
        guard isValidReceivedAt(metadata.receivedAt) else {
            throw ExternalPDFInboxError.invalidReceiveDate
        }
        let byteCount = Int64(fileSize)
        let expectedSHA256: String
        if let savedFingerprint = metadata.payloadSHA256,
           let savedByteCount = metadata.payloadByteCount {
            guard savedByteCount == byteCount,
                  isValidSHA256(savedFingerprint)
            else { return nil }
            expectedSHA256 = savedFingerprint.lowercased()
        } else if metadata.payloadSHA256 == nil,
                  metadata.payloadByteCount == nil {
            expectedSHA256 = try fileFingerprint(at: fileURL)
            try writeMetadata(
                Metadata(
                    preferredName: metadata.preferredName,
                    receivedAt: metadata.receivedAt,
                    payloadSHA256: expectedSHA256,
                    payloadByteCount: byteCount
                ),
                to: metadataURL,
                protectionHandler: { try requireCompleteProtection(at: $0) }
            )
        } else {
            return nil
        }
        return ExternalPDFInboxItem(
            id: itemID,
            containerURL: containerURL,
            fileURL: fileURL,
            preferredName: normalizedName(metadata.preferredName),
            receivedAt: metadata.receivedAt,
            expectedSHA256: expectedSHA256,
            byteCount: byteCount
        )
    }

    static func claim(
        _ item: ExternalPDFInboxItem,
        sharedContainerURL: URL? = nil
    ) throws -> ExternalPDFInboxItem {
        let directories = try importDirectories(
            sharedContainerURL: sharedContainerURL
        )
        let expectedURL = directories.inbox.appendingPathComponent(
            "\(item.id.uuidString).inbox",
            isDirectory: true
        )
        guard item.containerURL.standardizedFileURL
                == expectedURL.standardizedFileURL,
              try isValidContainer(
                item.containerURL,
                in: directories.inbox
              ),
              try metadataMatches(
                  item,
                  in: item.containerURL
              )
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        let claimedURL = directories.inbox.appendingPathComponent(
            "\(processingContainerPrefix)\(item.id.uuidString).inbox",
            isDirectory: true
        )
        guard !FileManager.default.fileExists(
            atPath: claimedURL.path
        ) else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        try FileManager.default.moveItem(
            at: item.containerURL,
            to: claimedURL
        )
        return relocatedItem(in: claimedURL, copying: item)
    }

    static func complete(
        _ claimedItem: ExternalPDFInboxItem,
        sharedContainerURL: URL? = nil
    ) throws {
        let directories = try importDirectories(
            sharedContainerURL: sharedContainerURL
        )
        guard try isClaimedContainer(
            claimedItem.containerURL,
            id: claimedItem.id,
            inboxURL: directories.inbox
        ) else {
            throw ExternalPDFInboxError.invalidPDF
        }
        let consumedURL = directories.inbox.appendingPathComponent(
            "\(consumedContainerPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: claimedItem.containerURL,
            to: consumedURL
        )
        try? FileManager.default.removeItem(at: consumedURL)
    }

    static func restore(
        _ claimedItem: ExternalPDFInboxItem,
        sharedContainerURL: URL? = nil
    ) throws {
        let directories = try importDirectories(
            sharedContainerURL: sharedContainerURL
        )
        guard try isClaimedContainer(
            claimedItem.containerURL,
            id: claimedItem.id,
            inboxURL: directories.inbox
        ) else { return }
        let restoredURL = directories.inbox.appendingPathComponent(
            "\(claimedItem.id.uuidString).inbox",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: restoredURL.path) {
            let claimed = try validatedItem(
                in: claimedItem.containerURL,
                id: claimedItem.id,
                inboxURL: directories.inbox
            )
            guard let claimed,
                  sameIdentity(claimed, claimedItem)
            else {
                throw ExternalPDFInboxError.incompleteCopy
            }
            if let queued = try validatedItem(
                in: restoredURL,
                id: claimedItem.id,
                inboxURL: directories.inbox
            ) {
                if sameIdentity(queued, claimed) {
                    try FileManager.default.removeItem(
                        at: claimedItem.containerURL
                    )
                } else {
                    let alternateURL = directories.inbox
                        .appendingPathComponent(
                            "\(UUID().uuidString).inbox",
                            isDirectory: true
                        )
                    try FileManager.default.moveItem(
                        at: claimedItem.containerURL,
                        to: alternateURL
                    )
                }
            } else {
                try FileManager.default.removeItem(at: restoredURL)
                try FileManager.default.moveItem(
                    at: claimedItem.containerURL,
                    to: restoredURL
                )
            }
        } else {
            try FileManager.default.moveItem(
                at: claimedItem.containerURL,
                to: restoredURL
            )
        }
    }

    private static func readMetadata(at url: URL) throws -> Metadata? {
        var refreshedURL = URL(
            fileURLWithPath: url.path,
            isDirectory: false
        )
        refreshedURL.removeAllCachedResourceValues()
        guard let values = try resourceValuesIfPresent(
            at: refreshedURL,
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumMetadataBytes
        else { return nil }
        let data = try boundedData(
            at: refreshedURL,
            maximumBytes: maximumMetadataBytes
        )
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private static func resourceValuesIfPresent(
        at url: URL,
        forKeys keys: Set<URLResourceKey>
    ) throws -> URLResourceValues? {
        do {
            return try url.resourceValues(forKeys: keys)
        } catch let error as CocoaError
        where error.code == .fileNoSuchFile
            || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func writeMetadata(
        _ metadata: Metadata,
        to url: URL,
        protectionHandler: (URL) throws -> Void
    ) throws {
        let data = try JSONEncoder().encode(metadata)
        guard data.count <= maximumMetadataBytes else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        let expectedFingerprint = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let directoryURL = url.deletingLastPathComponent()
        guard isContained(url, in: directoryURL),
              let directoryValues = try? directoryURL.resourceValues(
                  forKeys: [
                      .isDirectoryKey,
                      .isSymbolicLinkKey
                  ]
              ),
              directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        let replacesExistingFile = FileManager.default.fileExists(
            atPath: url.path
        )
        var previousFileIdentity: (
            byteCount: Int64,
            fingerprint: String
        )?
        if replacesExistingFile {
            let existingValues = try url.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard existingValues.isRegularFile == true,
                  existingValues.isSymbolicLink != true,
                  let existingByteCount = existingValues.fileSize,
                  existingByteCount > 0,
                  existingByteCount <= maximumMetadataBytes
            else {
                throw ExternalPDFInboxError.incompleteCopy
            }
            previousFileIdentity = (
                Int64(existingByteCount),
                try fileFingerprint(
                    at: url,
                    expectedByteCount: Int64(existingByteCount)
                )
            )
        }
        try ensureCapacity(sourceBytes: Int64(data.count), in: directoryURL)

        let stagingURL = directoryURL.appendingPathComponent(
            "\(metadataStagingPrefix)\(UUID().uuidString).json"
        )
        let backupURL = directoryURL.appendingPathComponent(
            "\(metadataRollbackPrefix)\(UUID().uuidString).json"
        )
        guard isContained(stagingURL, in: directoryURL),
              isContained(backupURL, in: directoryURL),
              !FileManager.default.fileExists(atPath: stagingURL.path),
              !FileManager.default.fileExists(atPath: backupURL.path),
              FileManager.default.createFile(
                  atPath: stagingURL.path,
                  contents: nil,
                  attributes: [.protectionKey: FileProtectionType.complete]
              )
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        var shouldRemoveBackup = true
        defer {
            try? FileManager.default.removeItem(at: stagingURL)
            if shouldRemoveBackup {
                try? FileManager.default.removeItem(at: backupURL)
            }
        }

        try protectionHandler(stagingURL)
        let output = try FileHandle(forWritingTo: stagingURL)
        do {
            try output.write(contentsOf: data)
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
        let stagingMetadataMatches = try metadataMatches(
            metadata,
            at: stagingURL
        )
        guard stagingMetadataMatches else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        let stagingFingerprint = try fileFingerprint(
            at: stagingURL,
            expectedByteCount: Int64(data.count)
        )
        guard stagingFingerprint == expectedFingerprint else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        try protectionHandler(stagingURL)
        excludeFromBackup(stagingURL)

        if replacesExistingFile {
            var replacementStarted = false
            do {
                replacementStarted = true
                _ = try FileManager.default.replaceItemAt(
                    url,
                    withItemAt: stagingURL,
                    backupItemName: backupURL.lastPathComponent,
                    options: [.withoutDeletingBackupItem]
                )
                try verifyPublishedMetadata(
                    metadata,
                    at: url,
                    expectedByteCount: Int64(data.count),
                    expectedFingerprint: expectedFingerprint,
                    protectionHandler: protectionHandler
                )
            } catch {
                guard replacementStarted,
                      FileManager.default.fileExists(
                          atPath: backupURL.path
                      ),
                      let previousFileIdentity
                else { throw error }
                do {
                    if FileManager.default.fileExists(
                        atPath: url.path
                    ) {
                        _ = try FileManager.default.replaceItemAt(
                            url,
                            withItemAt: backupURL
                        )
                    } else {
                        try FileManager.default.moveItem(
                            at: backupURL,
                            to: url
                        )
                    }
                    try protectionHandler(url)
                    excludeFromBackup(url)
                    guard try fileFingerprint(
                        at: url,
                        expectedByteCount:
                            previousFileIdentity.byteCount
                    ) == previousFileIdentity.fingerprint else {
                        throw ExternalPDFInboxError.incompleteCopy
                    }
                } catch {
                    shouldRemoveBackup = false
                    try? protectionHandler(backupURL)
                    excludeFromBackup(backupURL)
                    throw ExternalPDFInboxError.incompleteCopy
                }
                throw error
            }
        } else {
            var didPublish = false
            do {
                try FileManager.default.moveItem(
                    at: stagingURL,
                    to: url
                )
                didPublish = true
                try verifyPublishedMetadata(
                    metadata,
                    at: url,
                    expectedByteCount: Int64(data.count),
                    expectedFingerprint: expectedFingerprint,
                    protectionHandler: protectionHandler
                )
            } catch {
                if didPublish,
                   FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                throw error
            }
        }
    }

    private static func verifyPublishedMetadata(
        _ metadata: Metadata,
        at url: URL,
        expectedByteCount: Int64,
        expectedFingerprint: String,
        protectionHandler: (URL) throws -> Void
    ) throws {
        try protectionHandler(url)
        excludeFromBackup(url)
        guard try metadataMatches(metadata, at: url),
              try fileFingerprint(
                  at: url,
                  expectedByteCount: expectedByteCount
              ) == expectedFingerprint
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
    }

    private static func metadataMatches(
        _ metadata: Metadata,
        at url: URL
    ) throws -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = (attributes[.size] as? NSNumber)?.intValue,
              fileSize > 0,
              fileSize <= maximumMetadataBytes,
              let persisted = try readMetadata(at: url)
        else { return false }
        return persisted.preferredName == metadata.preferredName
            && abs(
                persisted.receivedAt.timeIntervalSince(
                    metadata.receivedAt
                )
            ) < 0.001
            && persisted.payloadSHA256 == metadata.payloadSHA256
            && persisted.payloadByteCount == metadata.payloadByteCount
    }

    static func remove(
        _ item: ExternalPDFInboxItem,
        sharedContainerURL: URL? = nil
    ) throws {
        let directories = try importDirectories(
            sharedContainerURL: sharedContainerURL
        )
        let expectedURL = directories.inbox.appendingPathComponent(
            "\(item.id.uuidString).inbox",
            isDirectory: true
        )
        guard item.containerURL.standardizedFileURL
                == expectedURL.standardizedFileURL,
              try isValidContainer(
                item.containerURL,
                in: directories.inbox
              )
        else { return }
        guard FileManager.default.fileExists(
            atPath: item.containerURL.path
        ) else { return }
        let consumedURL = directories.inbox.appendingPathComponent(
            "\(consumedContainerPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: item.containerURL,
            to: consumedURL
        )
        try? FileManager.default.removeItem(at: consumedURL)
    }

    static func removeAll(
        sharedContainerURL: URL? = nil
    ) throws {
        let containerURL = try resolvedContainerURL(
            sharedContainerURL
        )
        let rootURL = containerURL.appendingPathComponent(
            rootDirectoryName,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: rootURL.path)
        else { return }
        try FileManager.default.removeItem(at: rootURL)
    }

    private static func importDirectories(
        sharedContainerURL: URL?,
        protectionHandler: (URL) throws -> Void = {
            try requireCompleteProtection(at: $0)
        }
    ) throws -> (
        inbox: URL,
        staging: URL
    ) {
        let containerURL = try resolvedContainerURL(
            sharedContainerURL
        )

        let rootURL = containerURL.appendingPathComponent(
            rootDirectoryName,
            isDirectory: true
        )
        let inboxURL = rootURL.appendingPathComponent(
            inboxDirectoryName,
            isDirectory: true
        )
        let stagingURL = rootURL.appendingPathComponent(
            stagingDirectoryName,
            isDirectory: true
        )
        for (directory, parent) in [
            (rootURL, containerURL),
            (inboxURL, rootURL),
            (stagingURL, rootURL)
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            guard isContained(directory, in: parent),
                  let values = try? directory.resourceValues(
                      forKeys: [
                          .isDirectoryKey,
                          .isSymbolicLinkKey
                      ]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                throw ExternalPDFInboxError.sharedContainerUnavailable
            }
        }
        for directory in [rootURL, inboxURL, stagingURL] {
            try protectionHandler(directory)
        }
        pruneConsumedContainers(in: inboxURL)
        pruneStaleStaging(in: stagingURL)
        excludeFromBackup(rootURL)
        return (inboxURL, stagingURL)
    }

    private static func pruneConsumedContainers(in directory: URL) {
        guard let scan = try? boundedDirectoryContents(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            skipsHiddenFiles: false
        )
        else { return }
        let consumedEntries = scan.urls.lazy.filter {
            $0.lastPathComponent.hasPrefix(consumedContainerPrefix)
        }.prefix(maximumCleanupItemsPerPass)
        for entry in consumedEntries {
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey]
            )
            guard values?.isDirectory == true else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func recoverInterruptedClaims(
        in inboxURL: URL,
        excludingContainers: Set<URL>,
        deferredItems: inout [ExternalPDFInboxDeferredItem]
    ) throws -> Int {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]
        let scan = try boundedDirectoryContents(
            at: inboxURL,
            includingPropertiesForKeys: Array(keys),
            skipsHiddenFiles: false
        )
        guard !scan.isTruncated else {
            throw ExternalPDFInboxError.inboxFull
        }
        var discardedCount = 0
        for entry in scan.urls
        where entry.lastPathComponent.hasPrefix(
            processingContainerPrefix
        ) && entry.pathExtension == "inbox"
            && !excludingContainers.contains(entry) {
            try Task.checkCancellation()
            do {
                discardedCount += try recoverInterruptedClaim(
                    in: entry,
                    inboxURL: inboxURL
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                deferredItems.append(
                    ExternalPDFInboxDeferredItem(
                        containerURL: entry,
                        reason: retryReason(for: error)
                    )
                )
            }
        }
        return discardedCount
    }

    private static func recoverInterruptedClaim(
        in entry: URL,
        inboxURL: URL
    ) throws -> Int {
        let baseName = entry.deletingPathExtension().lastPathComponent
        let identifier = String(
            baseName.dropFirst(processingContainerPrefix.count)
        )
        guard let itemID = UUID(uuidString: identifier),
              try isValidContainer(entry, in: inboxURL)
        else {
            try FileManager.default.removeItem(at: entry)
            return 1
        }
        let restoredURL = inboxURL.appendingPathComponent(
            "\(itemID.uuidString).inbox",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: restoredURL.path) else {
            try FileManager.default.moveItem(at: entry, to: restoredURL)
            return 0
        }
        let processingItem = try validatedItem(
            in: entry,
            id: itemID,
            inboxURL: inboxURL
        )
        let queuedItem = try validatedItem(
            in: restoredURL,
            id: itemID,
            inboxURL: inboxURL
        )
        switch (processingItem, queuedItem) {
        case let (processing?, queued?) where sameIdentity(processing, queued):
            try FileManager.default.removeItem(at: entry)
            return 0
        case (_?, _?):
            let alternateURL = inboxURL.appendingPathComponent(
                "\(UUID().uuidString).inbox",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: entry, to: alternateURL)
            return 0
        case (_?, nil):
            try FileManager.default.removeItem(at: restoredURL)
            try FileManager.default.moveItem(at: entry, to: restoredURL)
            return 1
        case (nil, _?):
            try FileManager.default.removeItem(at: entry)
            return 1
        case (nil, nil):
            try FileManager.default.removeItem(at: entry)
            try FileManager.default.removeItem(at: restoredURL)
            return 2
        }
    }

    static func retryReason(for error: Error) -> ExternalPDFInboxError {
        if let inboxError = error as? ExternalPDFInboxError {
            return inboxError
        }
        var pending = [error as NSError]
        var inspectedCount = 0
        while let current = pending.popLast(), inspectedCount < 8 {
            inspectedCount += 1
            if current.domain == NSCocoaErrorDomain,
               current.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                return .insufficientStorage
            }
            if current.domain == NSPOSIXErrorDomain,
               current.code == Int(ENOSPC) || current.code == Int(EDQUOT) {
                return .insufficientStorage
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
            if let detailed = current.userInfo["NSDetailedErrors"] as? [NSError] {
                pending.append(contentsOf: detailed.prefix(4))
            }
        }
        return .temporarilyUnavailable
    }

    private static func ensureCapacity(
        sourceBytes: Int64,
        in directory: URL
    ) throws {
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available =
                values?.volumeAvailableCapacityForImportantUsage
        else { return }
        let reserve = Int64(16 * 1_024 * 1_024)
        let (copyBytes, copyOverflow) = sourceBytes
            .multipliedReportingOverflow(by: 2)
        let (required, addOverflow) = copyBytes
            .addingReportingOverflow(reserve)
        guard !copyOverflow,
              !addOverflow,
              available >= required
        else {
            throw ExternalPDFInboxError.insufficientStorage
        }
    }

    private static func pruneStaleStaging(in directory: URL) {
        let keys: [URLResourceKey] = [
            .creationDateKey,
            .contentModificationDateKey
        ]
        guard let scan = try? boundedDirectoryContents(
            at: directory,
            includingPropertiesForKeys: keys,
            skipsHiddenFiles: true
        )
        else { return }
        let cutoff = Date().addingTimeInterval(-stagingRetention)
        var removedCount = 0
        for entry in scan.urls {
            let values = try? entry.resourceValues(
                forKeys: Set(keys)
            )
            let date = values?.creationDate
                ?? values?.contentModificationDate
            guard let date, date < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
            removedCount += 1
            if removedCount >= maximumCleanupItemsPerPass {
                break
            }
        }
    }

    private static func resolvedContainerURL(
        _ override: URL?
    ) throws -> URL {
        if let override {
            return override
        }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ExternalPDFInboxError.sharedContainerUnavailable
        }
        return containerURL
    }

    private static func normalizedName(_ source: String) -> String {
        let sanitizedSource = source.unicodeScalars.map { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                codePoint == 0x061C
                || codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || isBidirectionalControl {
                return " "
            }
            return String(scalar)
        }
        .joined()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let trimmedSource = sanitizedSource
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let value = (trimmedSource as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty
            ? localized("Shared PDF")
            : String(value.prefix(120))
    }

    static func localized(_ key: String) -> String {
        let languageCode = selectedLanguageCode
        switch languageCode {
        case "en":
            return key
        case "zh-Hans":
            guard let path = Bundle.main.path(
                forResource: "zh-Hans",
                ofType: "lproj"
            ),
            let bundle = Bundle(path: path)
            else { return key }
            return bundle.localizedString(
                forKey: key,
                value: key,
                table: "Localizable"
            )
        default:
            return NSLocalizedString(key, comment: "")
        }
    }

    static var localizationLocale: Locale {
        switch selectedLanguageCode {
        case "en":
            return Locale(identifier: "en")
        case "zh-Hans":
            return Locale(identifier: "zh-Hans")
        default:
            return .autoupdatingCurrent
        }
    }

    private static var selectedLanguageCode: String {
        UserDefaults(
            suiteName: appGroupIdentifier
        )?.string(forKey: "app.language") ?? "system"
    }

    private static func boundedDirectoryContents(
        at directoryURL: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        skipsHiddenFiles: Bool
    ) throws -> (urls: [URL], isTruncated: Bool) {
        var options: FileManager.DirectoryEnumerationOptions = [
            .skipsSubdirectoryDescendants,
            .skipsPackageDescendants
        ]
        if skipsHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ExternalPDFInboxError.sharedContainerUnavailable
        }

        var urls: [URL] = []
        urls.reserveCapacity(maximumDirectoryEntriesToInspect)
        while urls.count < maximumDirectoryEntriesToInspect,
              let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            urls.append(url)
        }
        let isTruncated = enumerator.nextObject() != nil
        if let enumerationError {
            throw enumerationError
        }
        return (urls, isTruncated)
    }

    private static func metadataMatches(
        _ item: ExternalPDFInboxItem,
        in containerURL: URL
    ) throws -> Bool {
        try Task.checkCancellation()
        let fileURL = containerURL.appendingPathComponent(payloadFileName)
        let metadataURL = containerURL
            .appendingPathComponent(metadataFileName)
        guard fileURL.standardizedFileURL
                == item.fileURL.standardizedFileURL,
              let values = try? fileURL.resourceValues(
                  forKeys: [
                      .fileSizeKey,
                      .isRegularFileKey,
                      .isSymbolicLinkKey
                  ]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == item.byteCount,
              let metadata = try readMetadata(at: metadataURL),
              metadata.payloadByteCount == item.byteCount,
              metadata.payloadSHA256?.caseInsensitiveCompare(
                  item.expectedSHA256
              ) == .orderedSame,
              try hasPDFHeader(at: fileURL)
        else {
            return false
        }
        try requireCompleteProtection(at: fileURL)
        try requireCompleteProtection(at: metadataURL)
        return true
    }

    private static func pendingPayloadUsage(
        in inboxURL: URL
    ) throws -> (count: Int, bytes: Int64) {
        let scan = try boundedDirectoryContents(
            at: inboxURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            skipsHiddenFiles: false
        )
        guard !scan.isTruncated else {
            return (.max, .max)
        }

        var count = 0
        var bytes: Int64 = 0
        for container in scan.urls
        where container.pathExtension == "inbox" {
            try Task.checkCancellation()
            let baseName = container.deletingPathExtension()
                .lastPathComponent
            let isQueuedItem = UUID(uuidString: baseName) != nil
            let isClaimedItem = baseName.hasPrefix(
                processingContainerPrefix
            ) && UUID(
                uuidString: String(
                    baseName.dropFirst(
                        processingContainerPrefix.count
                    )
                )
            ) != nil
            guard isQueuedItem || isClaimedItem,
                  isContained(container, in: inboxURL),
                  let containerValues = try? container.resourceValues(
                      forKeys: [
                          .isDirectoryKey,
                          .isSymbolicLinkKey
                      ]
                  ),
                  containerValues.isDirectory == true,
                  containerValues.isSymbolicLink != true
            else {
                return (.max, .max)
            }
            let payload = container.appendingPathComponent(payloadFileName)
            guard let values = try? payload.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  Int64(size) <= maximumPayloadBytes
            else {
                return (.max, .max)
            }
            count += 1
            let (sum, overflow) = bytes.addingReportingOverflow(
                Int64(size)
            )
            bytes = overflow ? .max : sum
        }
        return (count, bytes)
    }

    private static func isContained(
        _ url: URL,
        in root: URL
    ) -> Bool {
        let rootPath = root.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let standardizedURL = url.standardizedFileURL
        let candidateURL: URL
        if FileManager.default.fileExists(atPath: standardizedURL.path) {
            candidateURL = standardizedURL.resolvingSymlinksInPath()
        } else {
            candidateURL = standardizedURL
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .appendingPathComponent(standardizedURL.lastPathComponent)
        }
        let candidatePath = candidateURL.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isValidContainer(
        _ url: URL,
        in inboxURL: URL
    ) throws -> Bool {
        guard isContained(url, in: inboxURL),
              url.deletingLastPathComponent().standardizedFileURL
                == inboxURL.standardizedFileURL,
              let values = try resourceValuesIfPresent(
                  at: url,
                  forKeys: [
                      .isDirectoryKey,
                      .isSymbolicLinkKey
                  ]
              ),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else { return false }
        return true
    }

    private static func isClaimedContainer(
        _ url: URL,
        id: UUID,
        inboxURL: URL
    ) throws -> Bool {
        try url.lastPathComponent
            == "\(processingContainerPrefix)\(id.uuidString).inbox"
            && isValidContainer(url, in: inboxURL)
    }

    private static func relocatedItem(
        in containerURL: URL,
        copying item: ExternalPDFInboxItem
    ) -> ExternalPDFInboxItem {
        ExternalPDFInboxItem(
            id: item.id,
            containerURL: containerURL,
            fileURL: containerURL
                .appendingPathComponent(payloadFileName),
            preferredName: item.preferredName,
            receivedAt: item.receivedAt,
            expectedSHA256: item.expectedSHA256,
            byteCount: item.byteCount
        )
    }

    private static func validatedItem(
        in containerURL: URL,
        id: UUID,
        inboxURL: URL
    ) throws -> ExternalPDFInboxItem? {
        guard try isValidContainer(containerURL, in: inboxURL) else {
            return nil
        }
        let fileURL = containerURL.appendingPathComponent(payloadFileName)
        let metadataURL = containerURL
            .appendingPathComponent(metadataFileName)
        guard let values = try resourceValuesIfPresent(
            at: fileURL,
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              Int64(fileSize) <= maximumPayloadBytes,
              let metadata = try readMetadata(at: metadataURL),
              let expectedSHA256 = metadata.payloadSHA256,
              let expectedByteCount = metadata.payloadByteCount,
              expectedByteCount == Int64(fileSize),
              isValidSHA256(expectedSHA256),
              try hasPDFHeader(at: fileURL)
        else {
            return nil
        }
        guard isValidReceivedAt(metadata.receivedAt) else {
            throw ExternalPDFInboxError.invalidReceiveDate
        }
        try requireCompleteProtection(at: fileURL)
        try requireCompleteProtection(at: metadataURL)
        let actualSHA256 = try fileFingerprint(at: fileURL)
        guard actualSHA256.caseInsensitiveCompare(expectedSHA256)
                == .orderedSame
        else {
            return nil
        }
        return ExternalPDFInboxItem(
            id: id,
            containerURL: containerURL,
            fileURL: fileURL,
            preferredName: normalizedName(metadata.preferredName),
            receivedAt: metadata.receivedAt,
            expectedSHA256: actualSHA256,
            byteCount: Int64(fileSize)
        )
    }

    private static func sameIdentity(
        _ lhs: ExternalPDFInboxItem,
        _ rhs: ExternalPDFInboxItem
    ) -> Bool {
        lhs.byteCount == rhs.byteCount
            && lhs.expectedSHA256.caseInsensitiveCompare(
                rhs.expectedSHA256
            ) == .orderedSame
    }

    private struct RegularFileIdentity: Equatable {
        let deviceID: UInt64
        let fileID: UInt64
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    private static func regularFileIdentity(
        for fileDescriptor: Int32
    ) throws -> RegularFileIdentity {
        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        return RegularFileIdentity(
            deviceID: UInt64(status.st_dev),
            fileID: UInt64(status.st_ino),
            byteCount: Int64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private static func regularFileIdentity(
        at url: URL
    ) throws -> RegularFileIdentity {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        defer { _ = Darwin.close(descriptor) }
        return try regularFileIdentity(for: descriptor)
    }

    private static func copyPayload(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedByteCount: Int64,
        protectionHandler: (URL) throws -> Void,
        progress: @Sendable (Int64, Int64) -> Void,
        cancellationCheck: () throws -> Void
    ) throws -> (
        byteCount: Int64,
        sha256: String,
        hasPDFHeader: Bool
    ) {
        guard FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil
        ) else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        try protectionHandler(destinationURL)

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let initialSourceIdentity = try regularFileIdentity(
            for: input.fileDescriptor
        )
        guard initialSourceIdentity.byteCount == expectedByteCount else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        var hasher = SHA256()
        var byteCount: Int64 = 0
        var lastReportedByteCount: Int64 = 0
        var header = Data()
        progress(0, expectedByteCount)
        while true {
            try cancellationCheck()
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            let (nextByteCount, overflow) = byteCount
                .addingReportingOverflow(Int64(data.count))
            guard !overflow,
                  nextByteCount <= expectedByteCount,
                  nextByteCount <= maximumPayloadBytes
            else {
                throw ExternalPDFInboxError.incompleteCopy
            }
            if header.count < 1_024 {
                header.append(
                    data.prefix(1_024 - header.count)
                )
            }
            try output.write(contentsOf: data)
            hasher.update(data: data)
            byteCount = nextByteCount
            if byteCount - lastReportedByteCount
                >= 4 * 1_024 * 1_024
                || byteCount == expectedByteCount {
                progress(byteCount, expectedByteCount)
                lastReportedByteCount = byteCount
            }
        }
        try cancellationCheck()
        try output.synchronize()
        let finalSourceIdentity = try regularFileIdentity(
            for: input.fileDescriptor
        )
        let currentSourceIdentity = try regularFileIdentity(at: sourceURL)
        guard byteCount == expectedByteCount,
              finalSourceIdentity == initialSourceIdentity,
              currentSourceIdentity == finalSourceIdentity
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        if byteCount != lastReportedByteCount {
            progress(byteCount, expectedByteCount)
        }
        let sha256 = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return (
            byteCount,
            sha256,
            header.range(of: Data("%PDF-".utf8)) != nil
        )
    }

    private static func hasPDFHeader(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 1_024),
              !data.isEmpty
        else { return false }
        return data.range(of: Data("%PDF-".utf8)) != nil
    }

    private static func fileFingerprint(
        at url: URL,
        expectedByteCount: Int64? = nil
    ) throws -> String {
        let values = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              Int64(fileSize) <= maximumPayloadBytes,
              expectedByteCount == nil
                || expectedByteCount == Int64(fileSize)
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let initialIdentity = try regularFileIdentity(
            for: handle.fileDescriptor
        )
        guard initialIdentity.byteCount == Int64(fileSize) else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        var hasher = SHA256()
        var processedByteCount: Int64 = 0
        let byteCount = Int64(fileSize)
        while processedByteCount < byteCount {
            try Task.checkCancellation()
            let requestedByteCount = Int(
                min(
                    Int64(1_048_576),
                    byteCount - processedByteCount
                )
            )
            let data = try handle.read(
                upToCount: requestedByteCount
            ) ?? Data()
            guard !data.isEmpty else {
                throw ExternalPDFInboxError.incompleteCopy
            }
            hasher.update(data: data)
            processedByteCount += Int64(data.count)
        }
        let trailingByte = try handle.read(upToCount: 1) ?? Data()
        guard trailingByte.isEmpty,
              processedByteCount == byteCount
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        let finalIdentity = try regularFileIdentity(
            for: handle.fileDescriptor
        )
        let currentIdentity = try regularFileIdentity(at: url)
        guard finalIdentity == initialIdentity,
              currentIdentity == finalIdentity
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        try Task.checkCancellation()
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdefABCDEF"
        )
        return value.count == 64
            && value.unicodeScalars.allSatisfy(hexadecimal.contains)
    }

    private static func isValidReceivedAt(_ date: Date) -> Bool {
        let timestamp = date.timeIntervalSince1970
        return timestamp.isFinite
            && timestamp >= 0
            && date <= Date().addingTimeInterval(5 * 60)
    }

    private static func boundedData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes >= 0,
              maximumBytes < Int.max
        else {
            throw ExternalPDFInboxError.invalidPDF
        }
        let values = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount >= 0,
              byteCount <= maximumBytes
        else {
            throw ExternalPDFInboxError.invalidPDF
        }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let initialIdentity = try regularFileIdentity(
            for: handle.fileDescriptor
        )
        guard initialIdentity.byteCount == Int64(byteCount) else {
            throw ExternalPDFInboxError.incompleteCopy
        }
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
                throw ExternalPDFInboxError.incompleteCopy
            }
            data.append(chunk)
        }
        let trailingByte = try handle.read(upToCount: 1) ?? Data()
        guard trailingByte.isEmpty,
              data.count == byteCount,
              data.count <= maximumBytes
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        let finalIdentity = try regularFileIdentity(
            for: handle.fileDescriptor
        )
        let currentIdentity = try regularFileIdentity(at: url)
        guard finalIdentity == initialIdentity,
              currentIdentity == finalIdentity
        else {
            throw ExternalPDFInboxError.incompleteCopy
        }
        try Task.checkCancellation()
        return data
    }

    private static func requireCompleteProtection(
        at url: URL
    ) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }
}
