import CryptoKit
import Foundation

public struct SnapshotRegion: Codable, Sendable {
    public let regionID: UUID
    public let regionName: String
    public let byteCount: Int
    public let bytes: Data
}

public struct MemorySnapshot: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public let regions: [SnapshotRegion]
    public let checksum: String
    public var capturedByteCount: Int { regions.reduce(0) { $0 + $1.byteCount } }
}

public struct SnapshotDifference: Sendable {
    public let regionID: UUID
    public let offset: Int
    public let oldByte: UInt8?
    public let newByte: UInt8?
}

public actor SnapshotStore {
    private let directory: URL
    private let maximumTotalBytes: Int
    private var snapshots: [UUID: MemorySnapshot] = [:]

    public init(directory: URL? = nil, maximumTotalBytes: Int = 64 * 1_024 * 1_024) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? support.appendingPathComponent("MemoryStudio/Snapshots", isDirectory: true)
        self.maximumTotalBytes = max(1, maximumTotalBytes)
    }

    public func restore() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }
        var restored: [UUID: MemorySnapshot] = [:]
        var total = 0
        for file in files {
            let (fileLimit, overflow) = maximumTotalBytes.multipliedReportingOverflow(by: 2)
            guard let fileSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                fileSize <= (overflow ? Int.max : fileLimit) else { throw MemoryEngineError.snapshotLimitExceeded }
            let snapshot = try JSONDecoder().decode(MemorySnapshot.self, from: Data(contentsOf: file))
            let (newTotal, overflow) = total.addingReportingOverflow(snapshot.capturedByteCount)
            guard !overflow, newTotal <= maximumTotalBytes else {
                throw MemoryEngineError.snapshotLimitExceeded
            }
            guard snapshot.checksum == Self.checksum(snapshot.regions) else {
                throw MemoryEngineError.snapshotIntegrityFailure(snapshot.id)
            }
            total = newTotal
            restored[snapshot.id] = snapshot
        }
        snapshots = restored
    }

    @discardableResult
    public func capture(name: String, regions: [RegisteredRegionSnapshot], maximumBytes: Int = 16 * 1_024 * 1_024) throws -> MemorySnapshot {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, maximumBytes > 0 else { throw MemoryEngineError.invalidValue("snapshot name or limit") }
        let captured = regions.map { SnapshotRegion(regionID: $0.info.id, regionName: $0.info.name, byteCount: $0.bytes.count, bytes: $0.bytes) }
        let (byteCount, byteCountOverflow) = captured.reduce(into: (0, false)) { state, region in
            let (next, overflow) = state.0.addingReportingOverflow(region.byteCount)
            state = (next, state.1 || overflow)
        }
        let (existingBytes, existingOverflow) = snapshots.values.reduce(into: (0, false)) { state, snapshot in
            let (next, overflow) = state.0.addingReportingOverflow(snapshot.capturedByteCount)
            state = (next, state.1 || overflow)
        }
        let (combined, combinedOverflow) = existingBytes.addingReportingOverflow(byteCount)
        guard !byteCountOverflow, !existingOverflow, byteCount <= maximumBytes,
              !combinedOverflow, combined <= maximumTotalBytes else {
            throw MemoryEngineError.snapshotLimitExceeded
        }
        let snapshot = MemorySnapshot(
            id: UUID(), name: cleanName, createdAt: Date(), regions: captured, checksum: Self.checksum(captured)
        )
        try persist(snapshot)
        snapshots[snapshot.id] = snapshot
        return snapshot
    }

    public func list() -> [MemorySnapshot] { snapshots.values.sorted { $0.createdAt > $1.createdAt } }

    public func rename(_ id: UUID, to name: String) throws {
        guard var snapshot = snapshots[id] else { throw MemoryEngineError.snapshotNotFound(id) }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw MemoryEngineError.invalidValue("snapshot name") }
        snapshot.name = cleanName
        try persist(snapshot)
        snapshots[id] = snapshot
    }

    public func delete(_ id: UUID) throws {
        guard snapshots[id] != nil else { return }
        let url = fileURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        snapshots[id] = nil
    }

    public func compare(_ oldID: UUID, to newID: UUID) throws -> [SnapshotDifference] {
        guard let old = snapshots[oldID] else { throw MemoryEngineError.snapshotNotFound(oldID) }
        guard let new = snapshots[newID] else { throw MemoryEngineError.snapshotNotFound(newID) }
        let oldRegions = Dictionary(uniqueKeysWithValues: old.regions.map { ($0.regionID, $0.bytes) })
        let newRegions = Dictionary(uniqueKeysWithValues: new.regions.map { ($0.regionID, $0.bytes) })
        var differences: [SnapshotDifference] = []
        for id in Set(oldRegions.keys).union(newRegions.keys) {
            let before = oldRegions[id] ?? Data()
            let after = newRegions[id] ?? Data()
            for offset in 0..<max(before.count, after.count) {
                let oldByte = offset < before.count ? before[offset] : nil
                let newByte = offset < after.count ? after[offset] : nil
                if oldByte != newByte {
                    differences.append(SnapshotDifference(regionID: id, offset: offset, oldByte: oldByte, newByte: newByte))
                }
            }
        }
        return differences.sorted { $0.regionID == $1.regionID ? $0.offset < $1.offset : $0.regionID.uuidString < $1.regionID.uuidString }
    }

    private func persist(_ snapshot: MemorySnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL(snapshot.id), options: .atomic)
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }

    private static func checksum(_ regions: [SnapshotRegion]) -> String {
        var data = Data()
        for region in regions.sorted(by: { $0.regionID.uuidString < $1.regionID.uuidString }) {
            data.append(contentsOf: region.regionID.uuidString.utf8)
            data.append(region.bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}