import Foundation

struct ExternalPDFInboxItem: Sendable {
    let containerURL: URL
    let fileURL: URL
    let preferredName: String
}

enum ExternalPDFInboxError: LocalizedError {
    case sharedContainerUnavailable
    case invalidPDF

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            return "PaperPath shared storage is unavailable."
        case .invalidPDF:
            return "That item is not a readable PDF."
        }
    }
}

enum ExternalPDFInbox {
    static let appGroupIdentifier = "group.com.monoware.paperpath"

    private struct Metadata: Codable {
        let preferredName: String
        let receivedAt: Date
    }

    private static let rootDirectoryName = "SharedImports"
    private static let inboxDirectoryName = "Inbox"
    private static let stagingDirectoryName = "Staging"
    private static let payloadFileName = "document.pdf"
    private static let metadataFileName = "metadata.json"

    static func stagePDF(
        from sourceURL: URL,
        suggestedName: String? = nil,
        sharedContainerURL: URL? = nil,
        protectionHandler: (URL) throws -> Void = {
            try requireCompleteProtection(at: $0)
        }
    ) throws -> ExternalPDFInboxItem {
        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard try hasPDFHeader(at: sourceURL) else {
            throw ExternalPDFInboxError.invalidPDF
        }

        let directories = try importDirectories(
            sharedContainerURL: sharedContainerURL,
            protectionHandler: protectionHandler
        )
        let identifier = UUID().uuidString
        let stagingURL = directories.staging
            .appendingPathComponent(identifier, isDirectory: true)
        let destinationURL = directories.inbox
            .appendingPathComponent("\(identifier).inbox", isDirectory: true)

        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false
        )
        try protectionHandler(stagingURL)

        do {
            let payloadURL = stagingURL.appendingPathComponent(payloadFileName)
            try FileManager.default.copyItem(at: sourceURL, to: payloadURL)
            try protectionHandler(payloadURL)

            let preferredName = normalizedName(
                suggestedName ?? sourceURL.lastPathComponent
            )
            let metadata = Metadata(
                preferredName: preferredName,
                receivedAt: Date()
            )
            let data = try JSONEncoder().encode(metadata)
            try data.write(
                to: stagingURL.appendingPathComponent(metadataFileName),
                options: .atomic
            )
            try protectionHandler(
                stagingURL.appendingPathComponent(metadataFileName)
            )

            try FileManager.default.moveItem(
                at: stagingURL,
                to: destinationURL
            )
            return ExternalPDFInboxItem(
                containerURL: destinationURL,
                fileURL: destinationURL
                    .appendingPathComponent(payloadFileName),
                preferredName: preferredName
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    static func pendingItems(
        sharedContainerURL: URL? = nil
    ) throws -> [ExternalPDFInboxItem] {
        try Task.checkCancellation()
        let directories = try importDirectories(
            sharedContainerURL: sharedContainerURL
        )
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .creationDateKey
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directories.inbox,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var datedContainers: [(url: URL, date: Date)] = []
        datedContainers.reserveCapacity(urls.count)
        for url in urls where url.pathExtension == "inbox" {
            try Task.checkCancellation()
            let date = try? url.resourceValues(
                forKeys: [.creationDateKey]
            ).creationDate
            datedContainers.append((url, date ?? .distantPast))
        }
        datedContainers.sort { $0.date < $1.date }

        var items: [ExternalPDFInboxItem] = []
        items.reserveCapacity(datedContainers.count)
        for entry in datedContainers {
            try Task.checkCancellation()
            let containerURL = entry.url
            let fileURL = containerURL
                .appendingPathComponent(payloadFileName)
            let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            guard values?.isRegularFile == true,
                  (try? hasPDFHeader(at: fileURL)) == true
            else { continue }

            let metadataURL = containerURL
                .appendingPathComponent(metadataFileName)
            let metadata: Metadata?
            if let data = try? Data(contentsOf: metadataURL) {
                metadata = try? JSONDecoder().decode(
                    Metadata.self,
                    from: data
                )
            } else {
                metadata = nil
            }
            items.append(
                ExternalPDFInboxItem(
                    containerURL: containerURL,
                    fileURL: fileURL,
                    preferredName:
                        metadata?.preferredName ?? "Shared PDF"
                )
            )
        }
        return items
    }

    static func remove(
        _ item: ExternalPDFInboxItem,
        sharedContainerURL: URL? = nil
    ) throws {
        let directories = try importDirectories(
            sharedContainerURL: sharedContainerURL
        )
        guard item.containerURL.pathExtension == "inbox",
              item.containerURL.deletingLastPathComponent()
                .standardizedFileURL
                == directories.inbox.standardizedFileURL
        else { return }
        try FileManager.default.removeItem(at: item.containerURL)
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
        try FileManager.default.createDirectory(
            at: inboxURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true
        )
        for directory in [rootURL, inboxURL, stagingURL] {
            try protectionHandler(directory)
        }
        excludeFromBackup(rootURL)
        return (inboxURL, stagingURL)
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
        let trimmedSource = source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let value = (trimmedSource as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Shared PDF" : String(value.prefix(120))
    }

    private static func hasPDFHeader(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 1_024),
              !data.isEmpty
        else { return false }
        return data.range(of: Data("%PDF-".utf8)) != nil
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
