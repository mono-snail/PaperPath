import Foundation

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

struct SavedSignatureLibrary: Codable, Sendable {
    var selectedID: UUID?
    var entries: [SavedSignature]

    static let empty = SavedSignatureLibrary(
        selectedID: nil,
        entries: []
    )
}

actor SignatureStore {
    static let maximumSignatureCount = 5

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

    func load() -> Data? {
        let library = loadLibrary()
        return selectedEntry(in: library)?.data
    }

    func loadLibrary() -> SavedSignatureLibrary {
        if let data = try? Data(contentsOf: libraryFileURL),
           let library = try? decoder.decode(
               SavedSignatureLibrary.self,
               from: data
           ) {
            return normalized(library)
        }

        guard let legacyData = try? Data(contentsOf: legacyFileURL),
              !legacyData.isEmpty
        else {
            return .empty
        }

        let entry = SavedSignature(data: legacyData)
        return SavedSignatureLibrary(
            selectedID: entry.id,
            entries: [entry]
        )
    }

    @discardableResult
    func add(_ data: Data) throws -> SavedSignatureLibrary {
        try validate(data)
        var library = loadLibrary()
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
        var library = loadLibrary()
        guard library.entries.contains(where: { $0.id == id }) else {
            return normalized(library)
        }
        library.selectedID = id
        try saveLibrary(library)
        return normalized(library)
    }

    @discardableResult
    func remove(id: UUID) throws -> SavedSignatureLibrary {
        var library = loadLibrary()
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
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try LocalFileSecurity.requireCompleteProtection(
            to: directory,
            fileManager: fileManager
        )
        let data = try encoder.encode(normalizedLibrary)
        let stagingURL = directory.appendingPathComponent(
            ".saved-signatures-\(UUID().uuidString).json"
        )
        defer {
            try? fileManager.removeItem(at: stagingURL)
        }
        try data.write(to: stagingURL, options: .atomic)
        try LocalFileSecurity.requireCompleteProtection(
            to: stagingURL,
            fileManager: fileManager
        )
        if fileManager.fileExists(atPath: libraryFileURL.path) {
            _ = try fileManager.replaceItemAt(
                libraryFileURL,
                withItemAt: stagingURL
            )
        } else {
            try fileManager.moveItem(
                at: stagingURL,
                to: libraryFileURL
            )
        }
        if fileManager.fileExists(atPath: legacyFileURL.path) {
            try? fileManager.removeItem(at: legacyFileURL)
        }
        LocalFileSecurity.excludeFromBackup(directory)
    }

    private func normalized(
        _ library: SavedSignatureLibrary
    ) -> SavedSignatureLibrary {
        var entries = Array(
            library.entries
                .filter { !$0.data.isEmpty }
                .prefix(Self.maximumSignatureCount)
        )
        var seen: Set<UUID> = []
        entries.removeAll { entry in
            if seen.contains(entry.id) { return true }
            seen.insert(entry.id)
            return false
        }
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
        guard data.count <= 5 * 1_024 * 1_024 else {
            throw PaperPathError.storageFailure(
                "The saved signature is too complex."
            )
        }
    }
}
