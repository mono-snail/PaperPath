import Foundation

@MainActor
protocol PDFMetadataKeyValueStore: AnyObject {
    var isCloudBacked: Bool { get }
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult
    func synchronize() -> Bool
}

@MainActor
final class ICloudMetadataKeyValueStore: PDFMetadataKeyValueStore {
    private var store: NSUbiquitousKeyValueStore?

    init(store: NSUbiquitousKeyValueStore? = nil) {
        self.store = store
    }

    var isCloudBacked: Bool { true }

    func data(forKey key: String) -> Data? {
        resolvedStore.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        if let data {
            resolvedStore.set(data, forKey: key)
        } else {
            resolvedStore.removeObject(forKey: key)
        }
    }

    func synchronize() -> Bool {
        resolvedStore.synchronize()
    }

    private var resolvedStore: NSUbiquitousKeyValueStore {
        if let store {
            return store
        }
        let store = NSUbiquitousKeyValueStore.default
        self.store = store
        return store
    }
}

@MainActor
final class LocalMetadataKeyValueStore: PDFMetadataKeyValueStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isCloudBacked: Bool { false }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func synchronize() -> Bool {
        true
    }
}

struct PDFMetadataSyncUpdate: Sendable {
    let recordID: UUID
    let fingerprint: String
    let lastPageIndex: Int
    let lastViewedAt: Date?
    let bookmarkedPages: [Int]
    let workflowStatus: DocumentWorkflowStatus
    let isPinned: Bool
    let tags: [String]
    let completedActions: Set<DocumentAction>
    let deliveryReceipt: PDFDeliveryReceipt?
    let updatedAt: Date
}

struct PDFMetadataSyncResult: Sendable {
    let updates: [PDFMetadataSyncUpdate]
    let eligibleDocumentCount: Int
    let duplicateDocumentCount: Int
    let cloudEntryCount: Int
    let isCloudAvailable: Bool
    let synchronizedAt: Date
}

struct PDFMetadataSyncStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case idle
        case syncing
        case synced
        case unavailable
        case failed
    }

    let state: State
    let documentCount: Int
    let updatedAt: Date?
    let detail: String

    static let idle = Self(
        state: .idle,
        documentCount: 0,
        updatedAt: nil,
        detail: "PDF files stay local. Lightweight metadata can sync through iCloud."
    )
}

@MainActor
final class PDFMetadataSyncService {
    private struct Versioned<
        Value: Codable & Hashable & Sendable
    >: Codable, Hashable, Sendable {
        let value: Value
        let modifiedAt: Date
    }

    private struct Snapshot: Codable, Hashable, Sendable {
        let fingerprint: String
        let pageCount: Int
        let readingPosition: Versioned<Int>
        let bookmarks: Versioned<[Int]>
        let workflow: Versioned<DocumentWorkflowStatus>
        let pinned: Versioned<Bool>
        let tags: Versioned<[String]>
        let completedActions: Versioned<Set<DocumentAction>>
        let receipt: Versioned<PDFDeliveryReceipt?>
        let lastSeenAt: Date

        var updatedAt: Date {
            [
                readingPosition.modifiedAt,
                bookmarks.modifiedAt,
                workflow.modifiedAt,
                pinned.modifiedAt,
                tags.modifiedAt,
                completedActions.modifiedAt,
                receipt.modifiedAt
            ].max() ?? lastSeenAt
        }
    }

    private struct Envelope: Codable, Sendable {
        let version: Int
        let snapshots: [Snapshot]

        static let empty = Envelope(version: 1, snapshots: [])
    }

    private let cloudStore: any PDFMetadataKeyValueStore
    private let shadowStore: any PDFMetadataKeyValueStore
    private let now: @MainActor () -> Date
    private let cloudKey = "paperpath.metadata.cloud.v1"
    private let shadowKey = "paperpath.metadata.shadow.v1"
    private let maximumCloudBytes = 900_000
    private let maximumEntries = 128
    private let retentionInterval: TimeInterval = 180 * 24 * 60 * 60
    private let baselineDate = Date(timeIntervalSince1970: 0)

    init(
        cloudStore: (any PDFMetadataKeyValueStore)? = nil,
        shadowStore: (any PDFMetadataKeyValueStore)? = nil,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.cloudStore = cloudStore
            ?? ICloudMetadataKeyValueStore()
        self.shadowStore = shadowStore
            ?? LocalMetadataKeyValueStore()
        self.now = now
    }

    func synchronize(
        records: [DocumentRecord]
    ) throws -> PDFMetadataSyncResult {
        let synchronizedAt = now()
        let cloudWasAvailable = cloudStore.synchronize()
        let remoteEnvelope = try envelope(
            from: cloudStore.data(forKey: cloudKey),
            source: "iCloud"
        )
        let shadowEnvelope = (
            try? envelope(
                from: shadowStore.data(forKey: shadowKey),
                source: "local sync"
            )
        ) ?? .empty
        var remoteByFingerprint = snapshotsByFingerprint(
            remoteEnvelope.snapshots
        )
        let shadowByFingerprint = snapshotsByFingerprint(
            shadowEnvelope.snapshots
        )

        let grouped = Dictionary(
            grouping: records.compactMap {
                record -> (String, DocumentRecord)? in
                guard let fingerprint = syncFingerprint(for: record)
                else { return nil }
                return (fingerprint, record)
            },
            by: \.0
        )
        var updates: [PDFMetadataSyncUpdate] = []
        var duplicateDocumentCount = 0

        for (fingerprint, entries) in grouped {
            try Task.checkCancellation()
            let candidates = entries.map(\.1)
            duplicateDocumentCount += max(0, candidates.count - 1)
            guard let record = candidates.max(by: {
                metadataActivityDate(for: $0)
                    < metadataActivityDate(for: $1)
            }) else { continue }
            let local = localSnapshot(
                for: record,
                fingerprint: fingerprint,
                previous: shadowByFingerprint[fingerprint],
                synchronizedAt: synchronizedAt
            )
            let merged = remoteByFingerprint[fingerprint].map {
                merge(local, $0, seenAt: synchronizedAt)
            } ?? local
            remoteByFingerprint[fingerprint] = merged

            if needsUpdate(record, from: merged) {
                updates.append(
                    PDFMetadataSyncUpdate(
                        recordID: record.id,
                        fingerprint: fingerprint,
                        lastPageIndex: min(
                            max(0, merged.readingPosition.value),
                            max(0, record.profile.pageCount - 1)
                        ),
                        lastViewedAt:
                            merged.readingPosition.modifiedAt,
                        bookmarkedPages: merged.bookmarks.value,
                        workflowStatus: merged.workflow.value,
                        isPinned: merged.pinned.value,
                        tags: merged.tags.value,
                        completedActions:
                            merged.completedActions.value,
                        deliveryReceipt: merged.receipt.value,
                        updatedAt: merged.updatedAt
                    )
                )
            }
        }

        let cutoff = synchronizedAt.addingTimeInterval(
            -retentionInterval
        )
        var cloudSnapshots = remoteByFingerprint.values
            .filter {
                $0.lastSeenAt >= cutoff
                    || grouped[$0.fingerprint] != nil
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        if cloudSnapshots.count > maximumEntries {
            cloudSnapshots.removeLast(
                cloudSnapshots.count - maximumEntries
            )
        }
        var cloudData = try encode(
            Envelope(version: 1, snapshots: cloudSnapshots)
        )
        while cloudData.count > maximumCloudBytes,
              cloudSnapshots.count > 1 {
            cloudSnapshots.removeLast()
            cloudData = try encode(
                Envelope(version: 1, snapshots: cloudSnapshots)
            )
        }
        guard cloudData.count <= maximumCloudBytes else {
            throw PaperPathError.storageFailure(
                "The iCloud metadata set exceeds the safe sync budget."
            )
        }

        cloudStore.set(cloudData, forKey: cloudKey)
        let cloudIsAvailable = cloudStore.synchronize()
            || cloudWasAvailable
        let localFingerprints = Set(grouped.keys)
        let localShadow = cloudSnapshots.filter {
            localFingerprints.contains($0.fingerprint)
        }
        shadowStore.set(
            try encode(
                Envelope(version: 1, snapshots: localShadow)
            ),
            forKey: shadowKey
        )

        return PDFMetadataSyncResult(
            updates: updates,
            eligibleDocumentCount: grouped.count,
            duplicateDocumentCount: duplicateDocumentCount,
            cloudEntryCount: cloudSnapshots.count,
            isCloudAvailable: cloudStore.isCloudBacked
                && cloudIsAvailable,
            synchronizedAt: synchronizedAt
        )
    }

    func clearSyncedMetadata() throws {
        cloudStore.set(nil, forKey: cloudKey)
        shadowStore.set(nil, forKey: shadowKey)
        let cloudDidSynchronize = cloudStore.synchronize()
        let shadowDidSynchronize = shadowStore.synchronize()
        guard cloudDidSynchronize, shadowDidSynchronize else {
            throw PaperPathError.storageFailure(
                "The synced metadata could not be cleared."
            )
        }
    }

    func clearLocalMetadata() {
        shadowStore.set(nil, forKey: shadowKey)
        _ = shadowStore.synchronize()
    }

    private func localSnapshot(
        for record: DocumentRecord,
        fingerprint: String,
        previous: Snapshot?,
        synchronizedAt: Date
    ) -> Snapshot {
        let metadataDate = metadataActivityDate(for: record)
        let normalizedRecordTags = normalizedTags(record.tags)
        return Snapshot(
            fingerprint: fingerprint,
            pageCount: record.profile.pageCount,
            readingPosition: versioned(
                record.lastPageIndex,
                previous: previous?.readingPosition,
                changedAt: changeDate(
                    value: record.lastPageIndex,
                    previous: previous?.readingPosition,
                    isMeaningful: record.lastViewedAt != nil
                        || record.lastPageIndex != 0,
                    localDate: record.lastViewedAt ?? metadataDate
                )
            ),
            bookmarks: versioned(
                record.bookmarkedPages.sorted(),
                previous: previous?.bookmarks,
                changedAt: changeDate(
                    value: record.bookmarkedPages.sorted(),
                    previous: previous?.bookmarks,
                    isMeaningful: !record.bookmarkedPages.isEmpty,
                    localDate: metadataDate
                )
            ),
            workflow: versioned(
                record.workflowStatus,
                previous: previous?.workflow,
                changedAt: changeDate(
                    value: record.workflowStatus,
                    previous: previous?.workflow,
                    isMeaningful: record.workflowStatus != .inbox,
                    localDate: metadataDate
                )
            ),
            pinned: versioned(
                record.isPinned,
                previous: previous?.pinned,
                changedAt: changeDate(
                    value: record.isPinned,
                    previous: previous?.pinned,
                    isMeaningful: record.isPinned,
                    localDate: metadataDate
                )
            ),
            tags: versioned(
                normalizedRecordTags,
                previous: previous?.tags,
                changedAt: changeDate(
                    value: normalizedRecordTags,
                    previous: previous?.tags,
                    isMeaningful: !normalizedRecordTags.isEmpty,
                    localDate: metadataDate
                )
            ),
            completedActions: versioned(
                record.completedActions,
                previous: previous?.completedActions,
                changedAt: changeDate(
                    value: record.completedActions,
                    previous: previous?.completedActions,
                    isMeaningful: !record.completedActions.isEmpty,
                    localDate: metadataDate
                )
            ),
            receipt: versioned(
                record.deliveryReceipt,
                previous: previous?.receipt,
                changedAt: changeDate(
                    value: record.deliveryReceipt,
                    previous: previous?.receipt,
                    isMeaningful: record.deliveryReceipt != nil,
                    localDate: record.deliveryReceipt?.createdAt
                        ?? metadataDate
                )
            ),
            lastSeenAt: synchronizedAt
        )
    }

    private func merge(
        _ local: Snapshot,
        _ remote: Snapshot,
        seenAt: Date
    ) -> Snapshot {
        Snapshot(
            fingerprint: local.fingerprint,
            pageCount: local.pageCount,
            readingPosition: newest(
                local.readingPosition,
                remote.readingPosition
            ),
            bookmarks: newest(local.bookmarks, remote.bookmarks),
            workflow: newest(local.workflow, remote.workflow),
            pinned: newest(local.pinned, remote.pinned),
            tags: newest(local.tags, remote.tags),
            completedActions: newest(
                local.completedActions,
                remote.completedActions
            ),
            receipt: newestReceipt(local.receipt, remote.receipt),
            lastSeenAt: seenAt
        )
    }

    private func newest<Value: Codable & Hashable & Sendable>(
        _ local: Versioned<Value>,
        _ remote: Versioned<Value>
    ) -> Versioned<Value> {
        remote.modifiedAt > local.modifiedAt ? remote : local
    }

    private func newestReceipt(
        _ local: Versioned<PDFDeliveryReceipt?>,
        _ remote: Versioned<PDFDeliveryReceipt?>
    ) -> Versioned<PDFDeliveryReceipt?> {
        switch (local.value, remote.value) {
        case (.some, .none):
            return local
        case (.none, .some):
            return remote
        case (.some, .some), (.none, .none):
            return newest(local, remote)
        }
    }

    private func versioned<Value: Codable & Hashable & Sendable>(
        _ value: Value,
        previous: Versioned<Value>?,
        changedAt: Date
    ) -> Versioned<Value> {
        if let previous, previous.value == value {
            return previous
        }
        return Versioned(value: value, modifiedAt: changedAt)
    }

    private func changeDate<
        Value: Codable & Hashable & Sendable
    >(
        value: Value,
        previous: Versioned<Value>?,
        isMeaningful: Bool,
        localDate: Date
    ) -> Date {
        if let previous, previous.value != value {
            return localDate
        }
        return isMeaningful ? localDate : baselineDate
    }

    private func needsUpdate(
        _ record: DocumentRecord,
        from snapshot: Snapshot
    ) -> Bool {
        record.lastPageIndex != min(
            max(0, snapshot.readingPosition.value),
            max(0, record.profile.pageCount - 1)
        )
            || record.bookmarkedPages
                != snapshot.bookmarks.value
                    .filter {
                        $0 >= 0
                            && $0 < record.profile.pageCount
                    }
                    .sorted()
            || record.workflowStatus != snapshot.workflow.value
            || record.isPinned != snapshot.pinned.value
            || normalizedTags(record.tags)
                != normalizedTags(snapshot.tags.value)
            || record.completedActions
                != snapshot.completedActions.value
            || record.deliveryReceipt != snapshot.receipt.value
    }

    private func syncFingerprint(
        for record: DocumentRecord
    ) -> String? {
        let candidate = record.contentFingerprint
        guard let candidate,
              candidate.count == 64,
              candidate.allSatisfy(\.isHexDigit)
        else { return nil }
        return candidate.lowercased()
    }

    private func snapshotsByFingerprint(
        _ snapshots: [Snapshot]
    ) -> [String: Snapshot] {
        snapshots.reduce(into: [:]) { result, snapshot in
            if let current = result[snapshot.fingerprint],
               current.updatedAt >= snapshot.updatedAt {
                return
            }
            result[snapshot.fingerprint] = snapshot
        }
    }

    private func metadataActivityDate(
        for record: DocumentRecord
    ) -> Date {
        [
            record.modifiedAt,
            record.lastViewedAt ?? record.importedAt,
            record.deliveryReceipt?.createdAt ?? record.importedAt
        ].max() ?? record.modifiedAt
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else { return nil }
            let shortened = String(trimmed.prefix(24))
            guard seen.insert(
                shortened.lowercased()
            ).inserted else { return nil }
            return shortened
        }.prefix(8).map { $0 }
    }

    private func envelope(
        from data: Data?,
        source: String
    ) throws -> Envelope {
        guard let data else { return .empty }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(
                Envelope.self,
                from: data
            )
            guard envelope.version == 1 else {
                throw PaperPathError.storageFailure(
                    "The \(source) metadata version is unsupported."
                )
            }
            return envelope
        } catch let error as PaperPathError {
            throw error
        } catch {
            throw PaperPathError.storageFailure(
                "The \(source) metadata could not be read safely."
            )
        }
    }

    private func encode(_ envelope: Envelope) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        } catch {
            throw PaperPathError.storageFailure(
                "The metadata sync state could not be encoded."
            )
        }
    }
}
