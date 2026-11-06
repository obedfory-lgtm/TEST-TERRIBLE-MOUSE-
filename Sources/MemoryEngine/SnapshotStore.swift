import CryptoKit
import Foundation

public struct MemorySnapshot: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public let regions: [SnapshotRegion]
    public let checksum: String
    public var exportStatus: String

    public var capturedByteCount: Int { regions.reduce(0) { $0 + $1.bytes.count } }
}

public struct SnapshotRegion: Codable, Sendable {
    public let regionID: UUID
    public let regionName: String
    public let sourceIdentifier: String
    public let bytes: Data
}

public enum SnapshotChangeKind: String, Equatable, Sendable {
    case changed
    case unchanged
    case added
    case removed
}

public struct SnapshotDifference: Sendable {
    public let regionID: UUID
    public let offset: Int
    public let oldByte: UInt8?
    public let newByte: UInt8?
    public let kind: SnapshotChangeKind
}

public actor SnapshotStore {
    private var snapshotsByID: [UUID: MemorySnapshot] = [:]
    private let maximumTotalBytes: Int
    private let directory: URL

    public init(
        maximumTotalBytes: Int = 128 * 1024 * 1024,
        directory: URL? = nil
    ) {
        self.maximumTotalBytes = max(1, maximumTotalBytes)
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = support.appendingPathComponent("DiagnosticHost/Snapshots", isDirectory: true)
        }
    }

    public func restore() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        var restored: [UUID: MemorySnapshot] = [:]
        var totalBytes = 0
        let (maximumFileSize, fileLimitOverflow) = maximumTotalBytes.multipliedReportingOverflow(by: 2)
        let fileLimit = fileLimitOverflow ? Int.max : maximumFileSize
        for url in urls {
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= fileLimit else {
                throw MemoryEngineError.snapshotLimitExceeded
            }
            let snapshot = try JSONDecoder().decode(MemorySnapshot.self, from: Data(contentsOf: url))
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(snapshot.capturedByteCount)
            guard !overflow, newTotal <= maximumTotalBytes else {
                throw MemoryEngineError.snapshotLimitExceeded
            }
            guard snapshot.checksum == Self.checksum(snapshot.regions) else {
                throw MemoryEngineError.invalidValue("snapshot checksum validation failed")
            }
            totalBytes = newTotal
            restored[snapshot.id] = snapshot
        }
        snapshotsByID = restored
    }

    @discardableResult
    public func capture(
        name: String,
        regions: [RegisteredRegionSnapshot],
        maximumBytes: Int = 64 * 1024 * 1024
    ) throws -> MemorySnapshot {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryEngineError.invalidValue("snapshot name")
        }
        guard maximumBytes > 0 else {
            throw MemoryEngineError.invalidValue("snapshot size limit")
        }
        let total = regions.reduce(0) { $0 + $1.bytes.count }
        let storedBytes = snapshotsByID.values.reduce(0) { $0 + $1.capturedByteCount }
        let (newStoredBytes, overflow) = storedBytes.addingReportingOverflow(total)
        guard total <= maximumBytes,
              !overflow,
              newStoredBytes <= maximumTotalBytes else {
            if !overflow, total <= maximumBytes, newStoredBytes > maximumTotalBytes {
                throw MemoryEngineError.snapshotLimitExceeded
            }
            throw MemoryEngineError.invalidValue("snapshot exceeds configured size limit")
        }
        let captured = regions.map {
            SnapshotRegion(
                regionID: $0.info.id,
                regionName: $0.info.name,
                sourceIdentifier: $0.info.id.uuidString,
                bytes: $0.bytes
            )
        }
        let checksum = Self.checksum(captured)
        let snapshot = MemorySnapshot(
            id: UUID(),
            name: name,
            createdAt: Date(),
            regions: captured,
            checksum: checksum,
            exportStatus: "not exported"
        )
        try persist(snapshot)
        snapshotsByID[snapshot.id] = snapshot
        return snapshot
    }

    public func list() -> [MemorySnapshot] {
        snapshotsByID.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func rename(_ id: UUID, to name: String) throws {
        guard var snapshot = snapshotsByID[id] else { throw MemoryEngineError.snapshotNotFound(id) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryEngineError.invalidValue("snapshot name")
        }
        snapshot.name = name
        try persist(snapshot)
        snapshotsByID[id] = snapshot
    }

    public func delete(_ id: UUID) throws {
        if let snapshot = snapshotsByID[id] {
            let url = fileURL(for: snapshot.id)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        snapshotsByID[id] = nil
    }

    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        snapshotsByID.removeAll(keepingCapacity: false)
    }

    public func compare(_ oldID: UUID, to newID: UUID) throws -> [SnapshotDifference] {
        guard let old = snapshotsByID[oldID] else { throw MemoryEngineError.snapshotNotFound(oldID) }
        guard let new = snapshotsByID[newID] else { throw MemoryEngineError.snapshotNotFound(newID) }
        let newByRegion = Dictionary(uniqueKeysWithValues: new.regions.map { ($0.regionID, $0) })
        var differences: [SnapshotDifference] = []
        let oldByRegion = Dictionary(uniqueKeysWithValues: old.regions.map { ($0.regionID, $0) })
        let allRegionIDs = Set(oldByRegion.keys).union(newByRegion.keys)
        for regionID in allRegionIDs {
            let oldBytes = oldByRegion[regionID]?.bytes ?? Data()
            let newBytes = newByRegion[regionID]?.bytes ?? Data()
            let commonCount = min(oldBytes.count, newBytes.count)
            for offset in 0..<commonCount {
                let oldByte = oldBytes[offset]
                let newByte = newBytes[offset]
                differences.append(SnapshotDifference(
                    regionID: regionID,
                    offset: offset,
                    oldByte: oldByte,
                    newByte: newByte,
                    kind: oldByte == newByte ? .unchanged : .changed
                ))
            }
            if oldBytes.count > commonCount {
                for offset in commonCount..<oldBytes.count {
                    differences.append(SnapshotDifference(
                        regionID: regionID,
                        offset: offset,
                        oldByte: oldBytes[offset],
                        newByte: nil,
                        kind: .removed
                    ))
                }
            } else if newBytes.count > commonCount {
                for offset in commonCount..<newBytes.count {
                    differences.append(SnapshotDifference(
                        regionID: regionID,
                        offset: offset,
                        oldByte: nil,
                        newByte: newBytes[offset],
                        kind: .added
                    ))
                }
            }
        }
        return differences.sorted {
            $0.regionID == $1.regionID ? $0.offset < $1.offset : $0.regionID.uuidString < $1.regionID.uuidString
        }
    }

    private func persist(_ snapshot: MemorySnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL(for: snapshot.id), options: .atomic)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private static func checksum(_ regions: [SnapshotRegion]) -> String {
        var data = Data()
        for region in regions.sorted(by: { $0.regionID.uuidString < $1.regionID.uuidString }) {
            data.append(contentsOf: region.regionID.uuidString.utf8)
            data.append(region.bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
