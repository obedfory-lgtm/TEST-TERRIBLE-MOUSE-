import Foundation

public struct MemoryRegionInfo: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let byteCount: Int
    public let isWritable: Bool
    public let dataType: MemoryDataType?
    public let registeredAt: Date
    public var lastObservedAt: Date?
}

public struct RegisteredRegionSnapshot: Sendable {
    public let info: MemoryRegionInfo
    public let bytes: Data
}

public actor MemoryRegionRegistry {
    private struct Entry {
        var info: MemoryRegionInfo
        var bytes: Data
    }

    private var entries: [UUID: Entry] = [:]
    public let maximumRegionSize: Int
    public let maximumTotalBytes: Int

    public init(maximumRegionSize: Int = 32 * 1_024 * 1_024, maximumTotalBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumRegionSize = max(1, maximumRegionSize)
        self.maximumTotalBytes = max(1, maximumTotalBytes)
    }

    @discardableResult
    public func register(
        name: String,
        bytes: Data,
        writable: Bool = false,
        dataType: MemoryDataType? = nil,
        id: UUID = UUID()
    ) throws -> MemoryRegionInfo {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bytes.count <= maximumRegionSize else {
            throw MemoryEngineError.invalidValue("region name or size")
        }
        guard entries[id] == nil else { throw MemoryEngineError.regionAlreadyRegistered(id) }
        let (total, overflow) = entries.values.reduce(into: (0, false)) { state, entry in
            let (next, didOverflow) = state.0.addingReportingOverflow(entry.info.byteCount)
            state = (next, state.1 || didOverflow)
        }
        let (newTotal, addOverflow) = total.addingReportingOverflow(bytes.count)
        guard !overflow, !addOverflow, newTotal <= maximumTotalBytes else {
            throw MemoryEngineError.regionLimitExceeded
        }
        let info = MemoryRegionInfo(
            id: id,
            name: name,
            byteCount: bytes.count,
            isWritable: writable,
            dataType: dataType,
            registeredAt: Date()
        )
        entries[id] = Entry(info: info, bytes: Data(bytes))
        return info
    }

    public func unregister(_ id: UUID) { entries[id] = nil }

    public func regions() -> [MemoryRegionInfo] {
        entries.values.map(\.info).sorted { $0.registeredAt < $1.registeredAt }
    }

    public func snapshots() -> [RegisteredRegionSnapshot] {
        entries.values.map { RegisteredRegionSnapshot(info: $0.info, bytes: Data($0.bytes)) }
            .sorted { $0.info.id.uuidString < $1.info.id.uuidString }
    }

    public func read(region id: UUID, range: Range<Int>) throws -> Data {
        guard var entry = entries[id] else { throw MemoryEngineError.regionNotRegistered(id) }
        guard range.lowerBound >= 0, range.upperBound <= entry.bytes.count else {
            throw MemoryEngineError.invalidRange
        }
        entry.info.lastObservedAt = Date()
        entries[id] = entry
        return entry.bytes.subdata(in: range)
    }

    public func write(region id: UUID, range: Range<Int>, bytes: Data) throws {
        guard var entry = entries[id] else { throw MemoryEngineError.regionNotRegistered(id) }
        guard entry.info.isWritable else { throw MemoryEngineError.readOnlyRegion(entry.info.name) }
        guard range.lowerBound >= 0, range.upperBound <= entry.bytes.count, range.count == bytes.count else {
            throw MemoryEngineError.invalidRange
        }
        entry.bytes.replaceSubrange(range, with: bytes)
        entry.info.lastObservedAt = Date()
        entries[id] = entry
    }
}