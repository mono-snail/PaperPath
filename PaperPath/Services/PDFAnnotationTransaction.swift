import CryptoKit
import Foundation

/// Keeps an original PDF recoverable until annotation publication commits.
struct PDFAnnotationTransaction {
    private static let recoveryPrefix = ".annotation-recovery-"
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private struct Journal: Codable {
        let originalDigest: String
        let updatedDigest: String
    }

    func publish(
        staging: URL,
        to destination: URL,
        sourceIsCurrent: () -> Bool
    ) throws {
        let directory = try recoveryDirectory(for: destination)
        if fileManager.fileExists(atPath: directory.path) {
            try recover(directory: directory, destination: destination)
            throw CocoaError(.fileWriteUnknown)
        }
        guard sourceIsCurrent() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let originalDigest = try digest(destination)
        let updatedDigest = try digest(staging)
        try LocalFileSecurity.prepareProtectedDirectory(
            at: directory,
            fileManager: fileManager
        )
        let backup = directory.appendingPathComponent("original.pdf")
        var hasJournal = false
        do {
            try fileManager.copyItem(at: destination, to: backup)
            try protect(backup)
            guard try digest(backup) == originalDigest else {
                throw CocoaError(.fileWriteUnknown)
            }
            let journal = Journal(
                originalDigest: originalDigest,
                updatedDigest: updatedDigest
            )
            let journalURL = directory.appendingPathComponent("journal.json")
            try JSONEncoder().encode(journal).write(
                to: journalURL,
                options: [.atomic, .completeFileProtection]
            )
            // A protected parent and atomic write make the journal safe
            // even if the subsequent protection verification fails.
            hasJournal = true
            try protect(journalURL)
            guard sourceIsCurrent(),
                  try digest(destination) == originalDigest
            else {
                // Nothing was published; an independent edit must survive.
                try finish(directory)
                throw CocoaError(.fileWriteUnknown)
            }
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: staging
            )
            try protect(destination)
            guard try digest(destination) == updatedDigest else {
                throw CocoaError(.fileWriteUnknown)
            }
            try finish(directory)
        } catch {
            if hasJournal,
               fileManager.fileExists(atPath: directory.path) {
                // Recovery copies the backup, so another restoration failure
                // cannot consume the only remaining original.
                try? recover(directory: directory, destination: destination)
            } else if !hasJournal {
                try? fileManager.removeItem(at: directory)
            }
            throw error
        }
    }

    func recoverAll(in documentsDirectory: URL) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        for directory in entries where directory.lastPathComponent
            .hasPrefix(Self.recoveryPrefix) {
            let name = String(
                directory.lastPathComponent.dropFirst(Self.recoveryPrefix.count)
            )
            let destination = documentsDirectory.appendingPathComponent(name)
            guard try recoveryDirectory(for: destination) == directory else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try recover(directory: directory, destination: destination)
        }
    }

    private func recover(
        directory: URL,
        destination: URL
    ) throws {
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let journalURL = directory.appendingPathComponent("journal.json")
        guard fileManager.fileExists(atPath: journalURL.path) else {
            // Publication only begins after the complete journal exists.
            try finish(directory)
            return
        }
        let attributes = try journalURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard attributes.isRegularFile == true,
              attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size <= 16_384 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let journal = try JSONDecoder().decode(
            Journal.self,
            from: Data(contentsOf: journalURL)
        )
        let currentDigest = fileManager.fileExists(atPath: destination.path)
            ? try digest(destination) : nil
        if currentDigest != journal.originalDigest {
            guard currentDigest == nil || currentDigest == journal.updatedDigest
            else {
                // Do not overwrite a separate edit made after the interruption.
                throw CocoaError(.fileWriteUnknown)
            }
            let backup = directory.appendingPathComponent("original.pdf")
            guard try digest(backup) == journal.originalDigest else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let restoration = directory.appendingPathComponent("restoration.pdf")
            if fileManager.fileExists(atPath: restoration.path) {
                try fileManager.removeItem(at: restoration)
            }
            try fileManager.copyItem(at: backup, to: restoration)
            try protect(restoration)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: restoration
                )
            } else {
                try fileManager.moveItem(at: restoration, to: destination)
            }
        }
        try protect(destination)
        guard try digest(destination) == journal.originalDigest else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try finish(directory)
    }

    private func recoveryDirectory(for destination: URL) throws -> URL {
        let name = destination.lastPathComponent
        guard destination.pathExtension == "pdf",
              UUID(uuidString: destination.deletingPathExtension()
                .lastPathComponent) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return destination.deletingLastPathComponent()
            .appendingPathComponent(Self.recoveryPrefix + name, isDirectory: true)
    }

    private func finish(_ directory: URL) throws {
        // Rename is the commit point. Recursive deletion is not atomic.
        let committed = directory.deletingLastPathComponent()
            .appendingPathComponent(".annotation-committed-\(UUID())")
        try fileManager.moveItem(at: directory, to: committed)
        try? fileManager.removeItem(at: committed)
    }

    private func protect(_ url: URL) throws {
        try LocalFileSecurity.requireCompleteProtection(
            to: url,
            fileManager: fileManager
        )
    }

    private func digest(_ url: URL) throws -> String {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let expectedSize = values.fileSize else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count = 0
        while let chunk = try handle.read(upToCount: 1_048_576),
              !chunk.isEmpty {
            count += chunk.count
            guard count <= expectedSize else {
                throw CocoaError(.fileReadCorruptFile)
            }
            hash.update(data: chunk)
        }
        guard count == expectedSize else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
