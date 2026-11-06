import Foundation

public struct SavedResultMetadata: Codable, Sendable {
    public let id: String
    public let regionID: UUID
    public let regionName: String
    public let offset: Int
    public let type: MemoryDataType
    public let initialValue: MemoryValue?
    public let previousValue: MemoryValue?
    public let currentValue: MemoryValue?
    public let observedAt: Date
}

public struct DiagnosticSession: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var selectedTypes: [MemoryDataType]
    public var filters: [String: String]
    public var results: [SavedResultMetadata]
    public var snapshotIDs: [UUID]
    public var exportNames: [String]

    public init(name: String, selectedTypes: [MemoryDataType] = [], filters: [String: String] = [:], results: [ScanResult] = [], snapshotIDs: [UUID] = [], exportNames: [String] = []) {
        id = UUID()
        self.name = name
        createdAt = Date()
        self.selectedTypes = selectedTypes
        self.filters = filters
        self.results = results.map {
            SavedResultMetadata(
                id: $0.id,
                regionID: $0.regionID,
                regionName: $0.regionName,
                offset: $0.offset,
                type: $0.dataType,
                initialValue: Self.persistable($0.initialValue),
                previousValue: Self.persistable($0.previousValue),
                currentValue: Self.persistable($0.currentValue),
                observedAt: $0.observedAt
            )
        }
        self.snapshotIDs = snapshotIDs
        self.exportNames = exportNames
    }

    private static func persistable(_ value: MemoryValue?) -> MemoryValue? {
        guard let value else { return nil }
        if case .bytes = value { return nil }
        return value
    }
}

public actor SessionStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? support.appendingPathComponent("MemoryStudio/Sessions", isDirectory: true)
    }

    public func save(_ session: DiagnosticSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(session).write(to: fileURL(session.id), options: .atomic)
    }

    public func load(_ id: UUID) throws -> DiagnosticSession {
        try JSONDecoder().decode(DiagnosticSession.self, from: Data(contentsOf: fileURL(id)))
    }

    public func list() throws -> [DiagnosticSession] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(DiagnosticSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ id: UUID) throws {
        let url = fileURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
}