import Foundation

public struct MemoryRegionInfo: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let baseAddress: UInt64?
    public let byteCount: Int
    public let isWritable: Bool
    public let dataType: MemoryDataType?
    public let registeredAt: Date
    public var lastObservedAt: Date?

    public init(
        id: UUID,
        name: String,
        baseAddress: UInt64? = nil,
        byteCount: Int,
        isWritable: Bool,
        dataType: MemoryDataType? = nil,
        registeredAt: Date,
        lastObservedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.baseAddress = baseAddress
        self.byteCount = byteCount
        self.isWritable = isWritable
        self.dataType = dataType
        self.registeredAt = registeredAt
        self.lastObservedAt = lastObservedAt
    }
}

public struct RegisteredRegionSnapshot: Sendable {
    public let info: MemoryRegionInfo
    public let bytes: Data

    public init(info: MemoryRegionInfo, bytes: Data) {
        self.info = info
        self.bytes = bytes
    }
}

public struct RegisteredBufferAccess: Sendable {
    public let read: @Sendable (Range<Int>) throws -> Data
    public let write: (@Sendable (Range<Int>, Data) throws -> Void)?

    public init(
        read: @escaping @Sendable (Range<Int>) throws -> Data,
        write: (@Sendable (Range<Int>, Data) throws -> Void)? = nil
    ) {
        self.read = read
        self.write = write
    }
}

public actor MemoryRegionRegistry {
    private struct Entry {
        var info: MemoryRegionInfo
        var bytes: Data?
        var access: RegisteredBufferAccess?
    }

    private var entries: [UUID: Entry] = [:]
    public let maximumRegionSize: Int
    public let maximumTotalBytes: Int

    public init(
        maximumRegionSize: Int = 64 * 1024 * 1024,
        maximumTotalBytes: Int = 128 * 1024 * 1024
    ) {
        self.maximumRegionSize = max(1, maximumRegionSize)
        self.maximumTotalBytes = max(1, maximumTotalBytes)
    }

    @discardableResult
    public func register(
        name: String,
        bytes: Data,
        writable: Bool = false,
        baseAddress: UInt64? = nil,
        dataType: MemoryDataType? = nil,
        id: UUID = UUID()
    ) throws -> MemoryRegionInfo {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bytes.count <= maximumRegionSize else {
            throw MemoryEngineError.invalidValue("region name or size")
        }
        guard entries[id] == nil else { throw MemoryEngineError.regionAlreadyRegistered(id) }
        try ensureCapacity(for: bytes.count)
        let info = MemoryRegionInfo(
            id: id,
            name: name,
            baseAddress: baseAddress,
            byteCount: bytes.count,
            isWritable: writable,
            dataType: dataType,
            registeredAt: Date()
        )
        entries[id] = Entry(info: info, bytes: bytes, access: nil)
        return info
    }

    @discardableResult
    public func register(
        name: String,
        byteCount: Int,
        writable: Bool = false,
        baseAddress: UInt64? = nil,
        dataType: MemoryDataType? = nil,
        id: UUID = UUID(),
        access: RegisteredBufferAccess
    ) throws -> MemoryRegionInfo {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              byteCount >= 0,
              byteCount <= maximumRegionSize,
              !writable || access.write != nil else {
            throw MemoryEngineError.invalidValue("region name, size, or write provider")
        }
        guard entries[id] == nil else { throw MemoryEngineError.regionAlreadyRegistered(id) }
        try ensureCapacity(for: byteCount)
        let info = MemoryRegionInfo(
            id: id,
            name: name,
            baseAddress: baseAddress,
            byteCount: byteCount,
            isWritable: writable,
            dataType: dataType,
            registeredAt: Date()
        )
        entries[id] = Entry(info: info, bytes: nil, access: access)
        return info
    }

    public func unregister(_ id: UUID) {
        entries[id] = nil
    }

    public func regions() -> [MemoryRegionInfo] {
        entries.values.map(\.info).sorted { $0.registeredAt < $1.registeredAt }
    }

    public func snapshots() throws -> [RegisteredRegionSnapshot] {
        let ids = entries.keys.sorted { $0.uuidString < $1.uuidString }
        var result: [RegisteredRegionSnapshot] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            guard var entry = entries[id] else { continue }
            let range = 0..<entry.info.byteCount
            let bytes: Data
            if let access = entry.access {
                bytes = try access.read(range)
            } else {
                guard let storedBytes = entry.bytes else { throw MemoryEngineError.invalidRange }
                bytes = storedBytes
            }
            guard bytes.count == entry.info.byteCount else { throw MemoryEngineError.invalidRange }
            entry.info.lastObservedAt = Date()
            entries[id] = entry
            result.append(RegisteredRegionSnapshot(info: entry.info, bytes: bytes))
        }
        return result
    }

    public func read(region id: UUID, range: Range<Int>) throws -> Data {
        guard var entry = entries[id] else { throw MemoryEngineError.regionNotRegistered(id) }
        guard range.lowerBound >= 0, range.upperBound <= entry.info.byteCount else {
            throw MemoryEngineError.invalidRange
        }
        let bytes: Data
        if let access = entry.access {
            bytes = try access.read(range)
            guard bytes.count == range.count else { throw MemoryEngineError.invalidRange }
        } else {
            guard let storedBytes = entry.bytes else { throw MemoryEngineError.invalidRange }
            bytes = storedBytes.subdata(in: range)
        }
        entry.info.lastObservedAt = Date()
        entries[id] = entry
        return bytes
    }

    public func write(region id: UUID, range: Range<Int>, bytes: Data) throws {
        guard var entry = entries[id] else { throw MemoryEngineError.regionNotRegistered(id) }
        guard entry.info.isWritable else { throw MemoryEngineError.readOnlyRegion(entry.info.name) }
        guard range.lowerBound >= 0,
              range.upperBound <= entry.info.byteCount,
              range.count == bytes.count else {
            throw MemoryEngineError.invalidRange
        }
        if let access = entry.access {
            guard let write = access.write else { throw MemoryEngineError.readOnlyRegion(entry.info.name) }
            try write(range, bytes)
        } else {
            guard var storedBytes = entry.bytes else { throw MemoryEngineError.invalidRange }
            storedBytes.replaceSubrange(range, with: bytes)
            entry.bytes = storedBytes
        }
        entry.info.lastObservedAt = Date()
        entries[id] = entry
    }

    private func ensureCapacity(for newByteCount: Int) throws {
        var currentByteCount = 0
        for entry in entries.values {
            let (next, overflow) = currentByteCount.addingReportingOverflow(entry.info.byteCount)
            guard !overflow else { throw MemoryEngineError.regionLimitExceeded }
            currentByteCount = next
        }
        let (total, overflow) = currentByteCount.addingReportingOverflow(newByteCount)
        guard !overflow, total <= maximumTotalBytes else {
            throw MemoryEngineError.regionLimitExceeded
        }
    }
}
