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

enum PDFMetadataSyncCommitError: Error {
    case remoteStateChanged
}

struct PDFMetadataSyncLocalState: Equatable, Sendable {
    let contentRevisionID: UUID
    let modifiedAt: Date
    let lastPageIndex: Int
    let lastViewedAt: Date?
    let bookmarkedPages: [Int]
    let workflowStatus: DocumentWorkflowStatus
    let isPinned: Bool
    let tags: [String]
    let completedActions: Set<DocumentAction>
    let deliveryReceipt: PDFDeliveryReceipt?

    init(_ record: DocumentRecord) {
        self.init(
            contentRevisionID: record.contentRevisionID,
            modifiedAt: record.modifiedAt,
            lastPageIndex: record.lastPageIndex,
            lastViewedAt: record.lastViewedAt,
            bookmarkedPages: record.bookmarkedPages,
            workflowStatus: record.workflowStatus,
            isPinned: record.isPinned,
            tags: record.tags,
            completedActions: record.completedActions,
            deliveryReceipt: record.deliveryReceipt
        )
    }

    init(
        contentRevisionID: UUID,
        modifiedAt: Date,
        lastPageIndex: Int,
        lastViewedAt: Date?,
        bookmarkedPages: [Int],
        workflowStatus: DocumentWorkflowStatus,
        isPinned: Bool,
        tags: [String],
        completedActions: Set<DocumentAction>,
        deliveryReceipt: PDFDeliveryReceipt?
    ) {
        self.contentRevisionID = contentRevisionID
        self.modifiedAt = modifiedAt
        self.lastPageIndex = lastPageIndex
        self.lastViewedAt = lastViewedAt
        self.bookmarkedPages = bookmarkedPages
        self.workflowStatus = workflowStatus
        self.isPinned = isPinned
        self.tags = tags
        self.completedActions = completedActions
        self.deliveryReceipt = deliveryReceipt
    }

    func matchesPersistenceRepresentation(
        of record: DocumentRecord
    ) -> Bool {
        contentRevisionID == record.contentRevisionID
            && Self.samePersistedDate(modifiedAt, record.modifiedAt)
            && lastPageIndex == record.lastPageIndex
            && Self.samePersistedDate(
                lastViewedAt,
                record.lastViewedAt
            )
            && bookmarkedPages == record.bookmarkedPages
            && workflowStatus == record.workflowStatus
            && isPinned == record.isPinned
            && tags == record.tags
            && completedActions == record.completedActions
            && Self.samePersistedReceipt(
                deliveryReceipt,
                record.deliveryReceipt
            )
    }

    private static func samePersistedDate(
        _ lhs: Date?,
        _ rhs: Date?
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            let lhsValue = lhs.timeIntervalSince1970
            let rhsValue = rhs.timeIntervalSince1970
            guard lhsValue.isFinite, rhsValue.isFinite else {
                return lhs == rhs
            }
            return lhsValue.rounded(.down)
                == rhsValue.rounded(.down)
        case (.none, .none):
            return true
        case (.some, .none), (.none, .some):
            return false
        }
    }

    private static func samePersistedReceipt(
        _ lhs: PDFDeliveryReceipt?,
        _ rhs: PDFDeliveryReceipt?
    ) -> Bool {
        if lhs == rhs {
            return true
        }
        guard let lhs, let rhs else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let lhsData = try? encoder.encode(lhs),
              let rhsData = try? encoder.encode(rhs)
        else {
            return false
        }
        return lhsData == rhsData
    }
}

struct PDFMetadataSyncUpdate: Sendable {
    let recordID: UUID
    let fingerprint: String
    let expectedLocalState: PDFMetadataSyncLocalState
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
        detail: "PDF files and extracted text stay local. Lightweight metadata can sync through iCloud."
    )
}

@MainActor
final class PDFMetadataSyncService {
    static let cloudStorageKey = "paperpath.metadata.cloud.v1"

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

    private struct SyncRecord: Sendable {
        let id: UUID
        let contentRevisionID: UUID
        let fingerprint: String?
        let pageCount: Int
        let lastPageIndex: Int
        let lastViewedAt: Date?
        let bookmarkedPages: [Int]
        let workflowStatus: DocumentWorkflowStatus
        let isPinned: Bool
        let tags: [String]
        let completedActions: Set<DocumentAction>
        let deliveryReceipt: PDFDeliveryReceipt?
        let importedAt: Date
        let modifiedAt: Date

        init(_ record: DocumentRecord) {
            id = record.id
            contentRevisionID = record.contentRevisionID
            fingerprint = record.contentFingerprint
            pageCount = record.profile.pageCount
            lastPageIndex = record.lastPageIndex
            lastViewedAt = record.lastViewedAt
            bookmarkedPages = record.bookmarkedPages
            workflowStatus = record.workflowStatus
            isPinned = record.isPinned
            tags = record.tags
            completedActions = record.completedActions
            deliveryReceipt = record.deliveryReceipt
            importedAt = record.importedAt
            modifiedAt = record.modifiedAt
        }

        var localState: PDFMetadataSyncLocalState {
            PDFMetadataSyncLocalState(
                contentRevisionID: contentRevisionID,
                modifiedAt: modifiedAt,
                lastPageIndex: lastPageIndex,
                lastViewedAt: lastViewedAt,
                bookmarkedPages: bookmarkedPages,
                workflowStatus: workflowStatus,
                isPinned: isPinned,
                tags: tags,
                completedActions: completedActions,
                deliveryReceipt: deliveryReceipt
            )
        }
    }

    private struct SyncConfiguration: Sendable {
        let maximumCloudBytes: Int
        let maximumEntries: Int
        let retentionInterval: TimeInterval
        let heartbeatInterval: TimeInterval
        let baselineDate: Date
    }

    struct PreparedSync: Sendable {
        let updates: [PDFMetadataSyncUpdate]
        let eligibleDocumentCount: Int
        let duplicateDocumentCount: Int
        let cloudEntryCount: Int
        let cloudData: Data
        let shadowData: Data
        let expectedCloudData: Data?
        let cloudWasAvailable: Bool
        let synchronizedAt: Date
    }

    private let cloudStore: any PDFMetadataKeyValueStore
    private let shadowStore: any PDFMetadataKeyValueStore
    private let now: @MainActor () -> Date
    private let shadowKey = "paperpath.metadata.shadow.v1"
    private let maximumCloudBytes = 900_000
    private let maximumEntries = 128
    private let retentionInterval: TimeInterval = 180 * 24 * 60 * 60
    private let heartbeatInterval: TimeInterval = 24 * 60 * 60
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
    ) async throws -> PDFMetadataSyncResult {
        let prepared = try await prepareSynchronization(records: records)
        return try commit(prepared)
    }

    func prepareSynchronization(
        records: [DocumentRecord]
    ) async throws -> PreparedSync {
        let synchronizedAt = now()
        let cloudWasAvailable = cloudStore.synchronize()
        let remoteData = cloudStore.data(
            forKey: Self.cloudStorageKey
        )
        let shadowData = shadowStore.data(forKey: shadowKey)
        let syncRecords = try await makeSyncRecords(from: records)
        let configuration = SyncConfiguration(
            maximumCloudBytes: maximumCloudBytes,
            maximumEntries: maximumEntries,
            retentionInterval: retentionInterval,
            heartbeatInterval: heartbeatInterval,
            baselineDate: baselineDate
        )
        let worker = Task.detached(priority: .utility) {
            try Self.prepare(
                records: syncRecords,
                remoteData: remoteData,
                shadowData: shadowData,
                synchronizedAt: synchronizedAt,
                configuration: configuration,
                cloudWasAvailable: cloudWasAvailable
            )
        }
        let prepared = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return prepared
    }

    func commit(
        _ prepared: PreparedSync
    ) throws -> PDFMetadataSyncResult {
        try Task.checkCancellation()
        let cloudIsCurrentlyAvailable = cloudStore.synchronize()
        guard cloudStore.data(forKey: Self.cloudStorageKey)
                == prepared.expectedCloudData
        else {
            throw PDFMetadataSyncCommitError.remoteStateChanged
        }
        try checkpointAppliedMetadata(prepared)
        try Task.checkCancellation()
        let cloudDataChanged =
            prepared.expectedCloudData != prepared.cloudData
        if cloudDataChanged {
            cloudStore.set(
                prepared.cloudData,
                forKey: Self.cloudStorageKey
            )
        }
        let cloudIsAvailable =
            (cloudDataChanged && cloudStore.synchronize())
                || cloudIsCurrentlyAvailable
                || prepared.cloudWasAvailable
        guard cloudStore.data(forKey: Self.cloudStorageKey)
                == prepared.cloudData
        else {
            throw PDFMetadataSyncCommitError.remoteStateChanged
        }

        return PDFMetadataSyncResult(
            updates: prepared.updates,
            eligibleDocumentCount: prepared.eligibleDocumentCount,
            duplicateDocumentCount: prepared.duplicateDocumentCount,
            cloudEntryCount: prepared.cloudEntryCount,
            isCloudAvailable: cloudStore.isCloudBacked
                && cloudIsAvailable,
            synchronizedAt: prepared.synchronizedAt
        )
    }

    func checkpointAppliedMetadata(
        _ prepared: PreparedSync
    ) throws {
        guard shadowStore.data(forKey: shadowKey)
                != prepared.shadowData
        else { return }
        shadowStore.set(prepared.shadowData, forKey: shadowKey)
        guard shadowStore.synchronize() else {
            throw PaperPathError.storageFailure(
                "The local metadata sync checkpoint could not be saved."
            )
        }
    }

    private func makeSyncRecords(
        from records: [DocumentRecord]
    ) async throws -> [SyncRecord] {
        var result: [SyncRecord] = []
        result.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 256) {
                try Task.checkCancellation()
                await Task.yield()
            }
            result.append(SyncRecord(record))
        }
        return result
    }

    nonisolated private static func prepare(
        records: [SyncRecord],
        remoteData: Data?,
        shadowData: Data?,
        synchronizedAt: Date,
        configuration: SyncConfiguration,
        cloudWasAvailable: Bool
    ) throws -> PreparedSync {
        let remoteEnvelope = try envelope(
            from: remoteData,
            source: "iCloud",
            referenceDate: synchronizedAt,
            configuration: configuration
        )
        let shadowEnvelope = (
            try? envelope(
                from: shadowData,
                source: "local sync",
                referenceDate: synchronizedAt,
                configuration: configuration
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
                record -> (String, SyncRecord)? in
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
                synchronizedAt: synchronizedAt,
                configuration: configuration
            )
            let merged = remoteByFingerprint[fingerprint].map {
                merge(local, $0)
            } ?? local
            remoteByFingerprint[fingerprint] = merged

            if needsUpdate(record, from: merged) {
                updates.append(
                    PDFMetadataSyncUpdate(
                        recordID: record.id,
                        fingerprint: fingerprint,
                        expectedLocalState: record.localState,
                        lastPageIndex: min(
                            max(0, merged.readingPosition.value),
                            max(0, record.pageCount - 1)
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
            -configuration.retentionInterval
        )
        var cloudSnapshots = remoteByFingerprint.values
            .filter {
                $0.lastSeenAt >= cutoff
                    || grouped[$0.fingerprint] != nil
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.fingerprint < $1.fingerprint
            }
        if cloudSnapshots.count > configuration.maximumEntries {
            cloudSnapshots.removeLast(
                cloudSnapshots.count - configuration.maximumEntries
            )
        }
        var cloudData = try encode(
            Envelope(version: 1, snapshots: cloudSnapshots)
        )
        while cloudData.count > configuration.maximumCloudBytes,
              cloudSnapshots.count > 1 {
            cloudSnapshots.removeLast()
            cloudData = try encode(
                Envelope(version: 1, snapshots: cloudSnapshots)
            )
        }
        guard cloudData.count <= configuration.maximumCloudBytes else {
            throw PaperPathError.storageFailure(
                "The iCloud metadata set exceeds the safe sync budget."
            )
        }

        let localFingerprints = Set(grouped.keys)
        let localShadow = cloudSnapshots.filter {
            localFingerprints.contains($0.fingerprint)
        }
        return PreparedSync(
            updates: updates,
            eligibleDocumentCount: grouped.count,
            duplicateDocumentCount: duplicateDocumentCount,
            cloudEntryCount: cloudSnapshots.count,
            cloudData: cloudData,
            shadowData: try encode(
                Envelope(version: 1, snapshots: localShadow)
            ),
            expectedCloudData: remoteData,
            cloudWasAvailable: cloudWasAvailable,
            synchronizedAt: synchronizedAt
        )
    }

    func clearSyncedMetadata() throws {
        cloudStore.set(nil, forKey: Self.cloudStorageKey)
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

    nonisolated private static func localSnapshot(
        for record: SyncRecord,
        fingerprint: String,
        previous: Snapshot?,
        synchronizedAt: Date,
        configuration: SyncConfiguration
    ) -> Snapshot {
        let metadataDate = canonicalLocalDate(
            metadataActivityDate(for: record),
            referenceDate: synchronizedAt,
            baselineDate: configuration.baselineDate
        )
        let readingDate = canonicalLocalDate(
            record.lastViewedAt ?? metadataDate,
            referenceDate: synchronizedAt,
            baselineDate: configuration.baselineDate
        )
        let normalizedRecordTags = normalizedTags(record.tags)
        let receiptSummary = metadataReceipt(record.deliveryReceipt)
            .flatMap {
                isValidSyncDate(
                    $0.createdAt,
                    referenceDate: synchronizedAt,
                    baselineDate: configuration.baselineDate
                ) ? $0 : nil
            }
        let normalizedBookmarks = normalizedBookmarks(
            record.bookmarkedPages,
            pageCount: record.pageCount
        )
        return Snapshot(
            fingerprint: fingerprint,
            pageCount: record.pageCount,
            readingPosition: versioned(
                record.lastPageIndex,
                previous: previous?.readingPosition,
                changedAt: changeDate(
                    value: record.lastPageIndex,
                    previous: previous?.readingPosition,
                    isMeaningful: record.lastViewedAt != nil
                        || record.lastPageIndex != 0,
                    localDate: readingDate,
                    baselineDate: configuration.baselineDate
                )
            ),
            bookmarks: versioned(
                normalizedBookmarks,
                previous: previous?.bookmarks,
                changedAt: changeDate(
                    value: normalizedBookmarks,
                    previous: previous?.bookmarks,
                    isMeaningful: !normalizedBookmarks.isEmpty,
                    localDate: metadataDate,
                    baselineDate: configuration.baselineDate
                )
            ),
            workflow: versioned(
                record.workflowStatus,
                previous: previous?.workflow,
                changedAt: changeDate(
                    value: record.workflowStatus,
                    previous: previous?.workflow,
                    isMeaningful: record.workflowStatus != .inbox,
                    localDate: metadataDate,
                    baselineDate: configuration.baselineDate
                )
            ),
            pinned: versioned(
                record.isPinned,
                previous: previous?.pinned,
                changedAt: changeDate(
                    value: record.isPinned,
                    previous: previous?.pinned,
                    isMeaningful: record.isPinned,
                    localDate: metadataDate,
                    baselineDate: configuration.baselineDate
                )
            ),
            tags: versioned(
                normalizedRecordTags,
                previous: previous?.tags,
                changedAt: changeDate(
                    value: normalizedRecordTags,
                    previous: previous?.tags,
                    isMeaningful: !normalizedRecordTags.isEmpty,
                    localDate: metadataDate,
                    baselineDate: configuration.baselineDate
                )
            ),
            completedActions: versioned(
                record.completedActions,
                previous: previous?.completedActions,
                changedAt: changeDate(
                    value: record.completedActions,
                    previous: previous?.completedActions,
                    isMeaningful: !record.completedActions.isEmpty,
                    localDate: metadataDate,
                    baselineDate: configuration.baselineDate
                )
            ),
            receipt: versioned(
                receiptSummary,
                previous: previous?.receipt,
                changedAt: changeDate(
                    value: receiptSummary,
                    previous: previous?.receipt,
                    isMeaningful: receiptSummary != nil,
                    localDate: canonicalLocalDate(
                        record.deliveryReceipt?.createdAt
                            ?? metadataDate,
                        referenceDate: synchronizedAt,
                        baselineDate: configuration.baselineDate
                    ),
                    baselineDate: configuration.baselineDate
                )
            ),
            lastSeenAt: refreshedLastSeenAt(
                previous?.lastSeenAt,
                synchronizedAt: synchronizedAt,
                heartbeatInterval:
                    configuration.heartbeatInterval
            )
        )
    }

    nonisolated private static func merge(
        _ local: Snapshot,
        _ remote: Snapshot
    ) -> Snapshot {
        Snapshot(
            fingerprint: local.fingerprint,
            pageCount: local.pageCount,
            readingPosition: newest(
                local.readingPosition,
                remote.readingPosition,
                prefersRemoteOnTie: { $0 < $1 }
            ),
            bookmarks: newest(
                local.bookmarks,
                remote.bookmarks,
                prefersRemoteOnTie: {
                    $0.lexicographicallyPrecedes($1)
                }
            ),
            workflow: newest(
                local.workflow,
                remote.workflow,
                prefersRemoteOnTie: { $0.rawValue < $1.rawValue }
            ),
            pinned: newest(
                local.pinned,
                remote.pinned,
                prefersRemoteOnTie: { !$0 && $1 }
            ),
            tags: newest(
                local.tags,
                remote.tags,
                prefersRemoteOnTie: {
                    $0.lexicographicallyPrecedes($1)
                }
            ),
            completedActions: newest(
                local.completedActions,
                remote.completedActions,
                prefersRemoteOnTie: { localValue, remoteValue in
                    localValue.map(\.rawValue).sorted()
                        .lexicographicallyPrecedes(
                            remoteValue.map(\.rawValue).sorted()
                        )
                }
            ),
            receipt: newestReceipt(local.receipt, remote.receipt),
            lastSeenAt: max(local.lastSeenAt, remote.lastSeenAt)
        )
    }

    nonisolated private static func refreshedLastSeenAt(
        _ previous: Date?,
        synchronizedAt: Date,
        heartbeatInterval: TimeInterval
    ) -> Date {
        guard let previous,
              previous
                >= synchronizedAt.addingTimeInterval(
                    -heartbeatInterval
                )
        else {
            return synchronizedAt
        }
        return previous
    }

    nonisolated private static func newest<
        Value: Codable & Hashable & Sendable
    >(
        _ local: Versioned<Value>,
        _ remote: Versioned<Value>,
        prefersRemoteOnTie: (Value, Value) -> Bool
    ) -> Versioned<Value> {
        if remote.modifiedAt != local.modifiedAt {
            return remote.modifiedAt > local.modifiedAt
                ? remote
                : local
        }
        guard remote.value != local.value else { return local }
        return prefersRemoteOnTie(local.value, remote.value)
            ? remote
            : local
    }

    nonisolated private static func newestReceipt(
        _ local: Versioned<PDFDeliveryReceipt?>,
        _ remote: Versioned<PDFDeliveryReceipt?>
    ) -> Versioned<PDFDeliveryReceipt?> {
        switch (local.value, remote.value) {
        case (.some, .none):
            return local
        case (.none, .some):
            return remote
        case (.some, .some), (.none, .none):
            return newest(
                local,
                remote,
                prefersRemoteOnTie: { localValue, remoteValue in
                    switch (localValue, remoteValue) {
                    case let (.some(localReceipt), .some(remoteReceipt)):
                        return localReceipt.id.uuidString
                            < remoteReceipt.id.uuidString
                    case (.none, .some):
                        return true
                    case (.some, .none), (.none, .none):
                        return false
                    }
                }
            )
        }
    }

    nonisolated private static func versioned<
        Value: Codable & Hashable & Sendable
    >(
        _ value: Value,
        previous: Versioned<Value>?,
        changedAt: Date
    ) -> Versioned<Value> {
        if let previous, previous.value == value {
            return previous
        }
        return Versioned(value: value, modifiedAt: changedAt)
    }

    nonisolated private static func changeDate<
        Value: Codable & Hashable & Sendable
    >(
        value: Value,
        previous: Versioned<Value>?,
        isMeaningful: Bool,
        localDate: Date,
        baselineDate: Date
    ) -> Date {
        if let previous, previous.value != value {
            return localDate
        }
        return isMeaningful ? localDate : baselineDate
    }

    nonisolated private static func needsUpdate(
        _ record: SyncRecord,
        from snapshot: Snapshot
    ) -> Bool {
        record.lastPageIndex != min(
            max(0, snapshot.readingPosition.value),
            max(0, record.pageCount - 1)
        )
            || record.bookmarkedPages
                != snapshot.bookmarks.value
                    .filter {
                        $0 >= 0
                            && $0 < record.pageCount
                    }
                    .sorted()
            || record.workflowStatus != snapshot.workflow.value
            || record.isPinned != snapshot.pinned.value
            || normalizedTags(record.tags)
                != normalizedTags(snapshot.tags.value)
            || record.completedActions
                != snapshot.completedActions.value
            || metadataReceipt(record.deliveryReceipt)
                != snapshot.receipt.value
    }

    nonisolated private static func syncFingerprint(
        for record: SyncRecord
    ) -> String? {
        let candidate = record.fingerprint
        guard let candidate,
              candidate.count == 64,
              candidate.allSatisfy(\.isHexDigit)
        else { return nil }
        return candidate.lowercased()
    }

    nonisolated private static func snapshotsByFingerprint(
        _ snapshots: [Snapshot]
    ) -> [String: Snapshot] {
        snapshots.reduce(into: [:]) { result, snapshot in
            let fingerprint = snapshot.fingerprint.lowercased()
            if let current = result[fingerprint],
               current.updatedAt >= snapshot.updatedAt {
                return
            }
            result[fingerprint] = snapshot
        }
    }

    nonisolated private static func metadataActivityDate(
        for record: SyncRecord
    ) -> Date {
        [
            record.modifiedAt,
            record.lastViewedAt ?? record.importedAt,
            record.deliveryReceipt?.createdAt ?? record.importedAt
        ].max() ?? record.modifiedAt
    }

    nonisolated private static func normalizedTags(
        _ tags: [String]
    ) -> [String] {
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

    nonisolated private static func envelope(
        from data: Data?,
        source: String,
        referenceDate: Date,
        configuration: SyncConfiguration
    ) throws -> Envelope {
        guard let data else { return .empty }
        guard data.count <= configuration.maximumCloudBytes else {
            throw PaperPathError.storageFailure(
                "The \(source) metadata exceeds the safe sync budget."
            )
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(
                Envelope.self,
                from: data
            )
            let sanitizedSnapshots = envelope.snapshots.map(
                sanitizedSnapshot
            )
            guard envelope.version == 1,
                  sanitizedSnapshots.count
                    <= configuration.maximumEntries,
                  sanitizedSnapshots.allSatisfy({
                      isStructurallyValid(
                          $0,
                          referenceDate: referenceDate,
                          baselineDate: configuration.baselineDate
                      )
                  })
            else {
                throw PaperPathError.storageFailure(
                    "The \(source) metadata is outside its safe limits."
                )
            }
            return Envelope(
                version: envelope.version,
                snapshots: sanitizedSnapshots
            )
        } catch let error as PaperPathError {
            throw error
        } catch {
            throw PaperPathError.storageFailure(
                "The \(source) metadata could not be read safely."
            )
        }
    }

    nonisolated private static func isStructurallyValid(
        _ snapshot: Snapshot,
        referenceDate: Date,
        baselineDate: Date
    ) -> Bool {
        let isFingerprintValid =
            snapshot.fingerprint.count == 64
                && snapshot.fingerprint.allSatisfy(\.isHexDigit)
        let pageCount = snapshot.pageCount
        let bookmarks = snapshot.bookmarks.value
        let tags = snapshot.tags.value
        let receipt = snapshot.receipt.value
        let dates = [
            snapshot.readingPosition.modifiedAt,
            snapshot.bookmarks.modifiedAt,
            snapshot.workflow.modifiedAt,
            snapshot.pinned.modifiedAt,
            snapshot.tags.modifiedAt,
            snapshot.completedActions.modifiedAt,
            snapshot.receipt.modifiedAt,
            snapshot.lastSeenAt
        ]
        return isFingerprintValid
            && (1...100_000).contains(pageCount)
            && snapshot.readingPosition.value >= 0
            && snapshot.readingPosition.value < pageCount
            && bookmarks.count <= min(max(0, pageCount), 100_000)
            && bookmarks == Array(Set(bookmarks)).sorted()
            && bookmarks.allSatisfy {
                $0 >= 0 && $0 < pageCount
            }
            && tags.count <= 8
            && tags.allSatisfy {
                !$0.isEmpty && $0.count <= 24
            }
            && snapshot.completedActions.value.count <= 32
            && dates.allSatisfy {
                isValidSyncDate(
                    $0,
                    referenceDate: referenceDate,
                    baselineDate: baselineDate
                )
            }
            && receipt.map { receipt in
                receipt.changeReview == nil
                    && receipt.sha256.count == 64
                    && receipt.sha256.allSatisfy(\.isHexDigit)
                    && receipt.sha256 == receipt.sha256.lowercased()
                    && receipt.isVerified
                    && receipt.sourcePageCount >= 0
                    && receipt.sourcePageCount <= 100_000
                    && receipt.outputPageCount >= 0
                    && receipt.outputPageCount <= 100_000
                    && receipt.sourceByteCount >= 0
                    && receipt.outputByteCount >= 0
                    && receipt.annotationCount >= 0
                    && receipt.textCharacterCount >= 0
                    && receipt.personalMetadataEntryCount >= 0
                    && receipt.unexpectedBlankPageIndices.allSatisfy {
                        $0 >= 0 && $0 < receipt.outputPageCount
                    }
                    && receipt.checks.count
                        <= PDFDeliveryPackageManifest.maximumCheckCount
                    && isValidSyncDate(
                        receipt.createdAt,
                        referenceDate: referenceDate,
                        baselineDate: baselineDate
                    )
            } ?? true
    }

    nonisolated private static func metadataReceipt(
        _ receipt: PDFDeliveryReceipt?
    ) -> PDFDeliveryReceipt? {
        receipt.map(canonicalReceipt)
    }

    nonisolated private static func sanitizedSnapshot(
        _ snapshot: Snapshot
    ) -> Snapshot {
        let pageCount = snapshot.pageCount
        let receipt = snapshot.receipt.value.map(canonicalReceipt)
        return Snapshot(
            fingerprint: snapshot.fingerprint.lowercased(),
            pageCount: pageCount,
            readingPosition: Versioned(
                value: min(
                    max(0, snapshot.readingPosition.value),
                    max(0, pageCount - 1)
                ),
                modifiedAt: snapshot.readingPosition.modifiedAt
            ),
            bookmarks: Versioned(
                value: normalizedBookmarks(
                    snapshot.bookmarks.value,
                    pageCount: pageCount
                ),
                modifiedAt: snapshot.bookmarks.modifiedAt
            ),
            workflow: snapshot.workflow,
            pinned: snapshot.pinned,
            tags: Versioned(
                value: normalizedTags(snapshot.tags.value),
                modifiedAt: snapshot.tags.modifiedAt
            ),
            completedActions: snapshot.completedActions,
            receipt: Versioned(
                value: receipt,
                modifiedAt: snapshot.receipt.modifiedAt
            ),
            lastSeenAt: snapshot.lastSeenAt
        )
    }

    nonisolated private static func normalizedBookmarks(
        _ bookmarks: [Int],
        pageCount: Int
    ) -> [Int] {
        Array(
            Set(
                bookmarks.filter {
                    $0 >= 0 && $0 < pageCount
                }
            )
        ).sorted()
    }

    nonisolated private static func canonicalReceipt(
        _ receipt: PDFDeliveryReceipt
    ) -> PDFDeliveryReceipt {
        let archived = receipt.milestoneArchiveCopy
        return PDFDeliveryReceipt(
            id: archived.id,
            operation: archived.operation,
            createdAt: persistedDate(archived.createdAt),
            sourcePageCount: archived.sourcePageCount,
            outputPageCount: archived.outputPageCount,
            renderedPageCount: archived.renderedPageCount,
            sourceByteCount: archived.sourceByteCount,
            outputByteCount: archived.outputByteCount,
            unexpectedBlankPageIndices:
                archived.unexpectedBlankPageIndices,
            annotationCount: archived.annotationCount,
            textCharacterCount: archived.textCharacterCount,
            personalMetadataEntryCount:
                archived.personalMetadataEntryCount,
            isEncrypted: archived.isEncrypted,
            sha256: archived.sha256.lowercased(),
            checks: archived.checks,
            changeReview: nil,
            sourceRevisionID: archived.sourceRevisionID,
            outputRevisionID: archived.outputRevisionID
        )
    }

    nonisolated private static func isValidSyncDate(
        _ date: Date,
        referenceDate: Date,
        baselineDate: Date
    ) -> Bool {
        let value = date.timeIntervalSince1970
        let latest = referenceDate.addingTimeInterval(5 * 60)
            .timeIntervalSince1970
        return value.isFinite
            && latest.isFinite
            && value >= baselineDate.timeIntervalSince1970
            && value <= latest
    }

    nonisolated private static func canonicalLocalDate(
        _ date: Date,
        referenceDate: Date,
        baselineDate: Date
    ) -> Date {
        let validDate = isValidSyncDate(
            date,
            referenceDate: referenceDate,
            baselineDate: baselineDate
        )
            ? date
            : referenceDate
        return persistedDate(validDate)
    }

    nonisolated private static func persistedDate(
        _ date: Date
    ) -> Date {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return date }
        return Date(
            timeIntervalSince1970: seconds.rounded(.down)
        )
    }

    nonisolated private static func encode(
        _ envelope: Envelope
    ) throws -> Data {
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
