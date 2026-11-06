import Foundation

public struct PersistedResultMetadata: Codable, Sendable {
    public let regionID: UUID
    public let offset: Int
    public let dataType: MemoryDataType
    public let displayValue: String?
    public let observedAt: Date

    public init(
        regionID: UUID,
        offset: Int,
        dataType: MemoryDataType,
        displayValue: String?,
        observedAt: Date
    ) {
        self.regionID = regionID
        self.offset = offset
        self.dataType = dataType
        self.displayValue = displayValue
        self.observedAt = observedAt
    }
}

public struct DiagnosticSession: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    public var selectedTypes: [MemoryDataType]
    public var scanMode: String
    public var filters: [String: String]
    public var results: [PersistedResultMetadata]
    public var snapshotIDs: [UUID]
    public var exportHistory: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedTypes: [MemoryDataType] = [],
        scanMode: String = "new",
        filters: [String: String] = [:],
        results: [PersistedResultMetadata] = [],
        snapshotIDs: [UUID] = [],
        exportHistory: [String] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selectedTypes = selectedTypes
        self.scanMode = scanMode
        self.filters = filters
        self.results = results
        self.snapshotIDs = snapshotIDs
        self.exportHistory = exportHistory
    }
}

public actor SessionStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = support.appendingPathComponent("DiagnosticHost/Sessions", isDirectory: true)
        }
    }

    public func save(_ session: DiagnosticSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(
            to: fileURL(for: session.id),
            options: .atomic
        )
    }

    public func load(_ id: UUID) throws -> DiagnosticSession {
        let data = try Data(contentsOf: fileURL(for: id))
        return try JSONDecoder().decode(DiagnosticSession.self, from: data)
    }

    public func list() throws -> [DiagnosticSession] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        return try urls.map { url in
            try JSONDecoder().decode(DiagnosticSession.self, from: Data(contentsOf: url))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}
