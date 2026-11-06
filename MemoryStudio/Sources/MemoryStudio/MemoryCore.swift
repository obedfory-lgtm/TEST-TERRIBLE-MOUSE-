import Foundation

public enum MemoryEngineError: Error, LocalizedError, Equatable {
    case invalidValue(String)
    case invalidPattern(String)
    case invalidRange
    case regionNotRegistered(UUID)
    case regionAlreadyRegistered(UUID)
    case regionLimitExceeded
    case readOnlyRegion(String)
    case snapshotLimitExceeded
    case snapshotNotFound(UUID)
    case snapshotIntegrityFailure(UUID)
    case invalidFilename
    case fileAlreadyExists(String)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let value): "Invalid value: \(value)."
        case .invalidPattern(let pattern): "Invalid byte pattern: \(pattern)."
        case .invalidRange: "The requested range is outside the registered region."
        case .regionNotRegistered(let id): "Region \(id.uuidString) is not registered."
        case .regionAlreadyRegistered(let id): "Region \(id.uuidString) is already registered."
        case .regionLimitExceeded: "The registered-memory limit would be exceeded."
        case .readOnlyRegion(let name): "Region \(name) is read-only."
        case .snapshotLimitExceeded: "The configured snapshot storage limit would be exceeded."
        case .snapshotNotFound(let id): "Snapshot \(id.uuidString) was not found."
        case .snapshotIntegrityFailure(let id): "Snapshot \(id.uuidString) failed its SHA-256 integrity check."
        case .invalidFilename: "The filename is empty or contains unsupported characters."
        case .fileAlreadyExists(let name): "A file named \(name) already exists."
        case .unsupportedFormat(let format): "The \(format) format is unsupported for this payload."
        }
    }
}

public enum ByteOrder: String, Codable, CaseIterable, Hashable, Sendable {
    case littleEndian
    case bigEndian
}

public enum MemoryDataType: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case int8, uint8, int16, uint16, int32, uint32, int64, uint64
    case float32, float64, boolean, utf8, utf16, ascii, bytes

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .int8: "Int8"
        case .uint8: "UInt8"
        case .int16: "Int16"
        case .uint16: "UInt16"
        case .int32: "Int32"
        case .uint32: "UInt32"
        case .int64: "Int64"
        case .uint64: "UInt64"
        case .float32: "Float32"
        case .float64: "Float64"
        case .boolean: "Boolean"
        case .utf8: "UTF-8"
        case .utf16: "UTF-16"
        case .ascii: "ASCII"
        case .bytes: "Bytes"
        }
    }

    public var width: Int? {
        switch self {
        case .int8, .uint8, .boolean: 1
        case .int16, .uint16: 2
        case .int32, .uint32, .float32: 4
        case .int64, .uint64, .float64: 8
        case .utf8, .utf16, .ascii, .bytes: nil
        }
    }

    public var isNumeric: Bool { width != nil }

    public func decode(_ data: Data, byteOrder: ByteOrder = .littleEndian) throws -> MemoryValue {
        try decode(data, range: data.startIndex..<data.endIndex, byteOrder: byteOrder)
    }

    public func decode(_ data: Data, range: Range<Int>, byteOrder: ByteOrder = .littleEndian) throws -> MemoryValue {
        guard range.lowerBound >= data.startIndex, range.upperBound <= data.endIndex else {
            throw MemoryEngineError.invalidRange
        }
        if let width {
            guard range.count == width else { throw MemoryEngineError.invalidRange }
            let raw = Self.readInteger(data[range], byteOrder: byteOrder)
            switch self {
            case .int8: return .signed(Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: raw))))
            case .uint8: return .unsigned(UInt64(UInt8(truncatingIfNeeded: raw)))
            case .int16: return .signed(Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: raw))))
            case .uint16: return .unsigned(UInt64(UInt16(truncatingIfNeeded: raw)))
            case .int32: return .signed(Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw))))
            case .uint32: return .unsigned(UInt64(UInt32(truncatingIfNeeded: raw)))
            case .int64: return .signed(Int64(bitPattern: raw))
            case .uint64: return .unsigned(raw)
            case .float32: return .floating(Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))))
            case .float64: return .floating(Double(bitPattern: raw))
            case .boolean: return .boolean(raw != 0)
            case .utf8, .utf16, .ascii, .bytes: break
            }
        }

        switch self {
        case .utf8:
            guard let text = String(data: Data(data[range]), encoding: .utf8) else { throw MemoryEngineError.invalidValue("UTF-8") }
            return .text(text)
        case .utf16:
            let encoding: String.Encoding = byteOrder == .littleEndian ? .utf16LittleEndian : .utf16BigEndian
            guard let text = String(data: Data(data[range]), encoding: encoding) else { throw MemoryEngineError.invalidValue("UTF-16") }
            return .text(text)
        case .ascii:
            guard let text = String(data: Data(data[range]), encoding: .ascii) else { throw MemoryEngineError.invalidValue("ASCII") }
            return .text(text)
        case .bytes: return .bytes(Array(data[range]))
        default: throw MemoryEngineError.invalidRange
        }
    }

    public func encode(_ source: String, byteOrder: ByteOrder = .littleEndian) throws -> Data {
        guard let width else {
            switch self {
            case .utf8: return Data(source.utf8)
            case .utf16:
                var data = Data()
                for unit in source.utf16 {
                    var value = byteOrder == .littleEndian ? unit.littleEndian : unit.bigEndian
                    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
                }
                return data
            case .ascii:
                guard let data = source.data(using: .ascii) else { throw MemoryEngineError.invalidValue(source) }
                return data
            case .bytes: return try BytePattern.parse(source).concreteData()
            default: throw MemoryEngineError.invalidValue(source)
            }
        }

        let raw: UInt64
        switch self {
        case .int8:
            guard let value = Int8(source) else { throw MemoryEngineError.invalidValue(source) }
            raw = UInt64(UInt8(bitPattern: value))
        case .uint8:
            guard let value = UInt8(source) else { throw MemoryEngineError.invalidValue(source) }
            raw = UInt64(value)
        case .int16:
            guard let value = Int16(source) else { throw MemoryEngineError.invalidValue(source) }
            raw = UInt64(UInt16(bitPattern: value))
        case .uint16:
            guard let value = UInt16(source) else { throw MemoryEngineError.invalidValue(source) }
            raw = UInt64(value)
        case .int32:
            guard let value = Int32(source) else { throw MemoryEngineError.invalidValue(source) }
            raw = UInt64(UInt32(bitPattern: value))
        case .uint32:
            guard let value = UInt32(source) else { throw MemoryEngineError.invalidValue(source) }
            raw = UInt64(value)
        case .int64:
            guard let value = Int64(source) else { throw MemoryEngineError.invalidValue(source) }
            raw = UInt64(bitPattern: value)
        case .uint64:
            guard let value = UInt64(source) else { throw MemoryEngineError.invalidValue(source) }
            raw = value
        case .float32:
            guard let value = Float(source), value.isFinite else { throw MemoryEngineError.invalidValue(source) }
            raw = UInt64(value.bitPattern)
        case .float64:
            guard let value = Double(source), value.isFinite else { throw MemoryEngineError.invalidValue(source) }
            raw = value.bitPattern
        case .boolean:
            let normalized = source.lowercased()
            guard ["true", "false", "1", "0"].contains(normalized) else {
                throw MemoryEngineError.invalidValue(source)
            }
            raw = ["true", "1"].contains(normalized) ? 1 : 0
        case .utf8, .utf16, .ascii, .bytes: throw MemoryEngineError.invalidValue(source)
        }

        var data = Data()
        for index in 0..<width {
            let shift = byteOrder == .littleEndian ? index : width - index - 1
            data.append(UInt8(truncatingIfNeeded: raw >> (shift * 8)))
        }
        return data
    }

    private static func readInteger<C: Collection>(_ data: C, byteOrder: ByteOrder) -> UInt64 where C.Element == UInt8 {
        switch byteOrder {
        case .littleEndian:
            return data.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
        case .bigEndian:
            return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
    }
}

public enum MemoryValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case signed(Int64)
    case unsigned(UInt64)
    case floating(Double)
    case boolean(Bool)
    case text(String)
    case bytes([UInt8])

    public var description: String {
        switch self {
        case .signed(let value): String(value)
        case .unsigned(let value): String(value)
        case .floating(let value): String(value)
        case .boolean(let value): String(value)
        case .text(let value): value
        case .bytes(let value): value.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    public func compared(to other: MemoryValue, tolerance: Double = 0) -> ComparisonResult? {
        switch (self, other) {
        case (.signed(let lhs), .signed(let rhs)):
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.unsigned(let lhs), .unsigned(let rhs)):
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.floating(let lhs), .floating(let rhs)):
            guard lhs.isFinite, rhs.isFinite else { return nil }
            if abs(lhs - rhs) <= tolerance { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        case (.boolean(let lhs), .boolean(let rhs)):
            return lhs == rhs ? .orderedSame : (lhs ? .orderedDescending : .orderedAscending)
        case (.text(let lhs), .text(let rhs)):
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.bytes(let lhs), .bytes(let rhs)):
            return lhs == rhs ? .orderedSame : (lhs.lexicographicallyPrecedes(rhs) ? .orderedAscending : .orderedDescending)
        default: return nil
        }
    }
}

public struct BytePattern: Equatable, Sendable {
    public let bytes: [UInt8?]

    public init(bytes: [UInt8?]) { self.bytes = bytes }

    public static func parse(_ source: String) throws -> BytePattern {
        let tokens = source.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { throw MemoryEngineError.invalidPattern(source) }
        let parsed = try tokens.map { token -> UInt8? in
            if token == "??" { return nil }
            guard token.count == 2, let value = UInt8(token, radix: 16) else {
                throw MemoryEngineError.invalidPattern(source)
            }
            return value
        }
        return BytePattern(bytes: parsed)
    }

    public func matches(_ data: Data, at offset: Int) -> Bool {
        guard !bytes.isEmpty, offset >= 0, offset <= data.count - bytes.count else { return false }
        return bytes.enumerated().allSatisfy { index, expected in
            expected == nil || expected == data[data.startIndex + offset + index]
        }
    }

    public func concreteData() throws -> Data {
        guard bytes.allSatisfy({ $0 != nil }) else {
            throw MemoryEngineError.invalidPattern("wildcards cannot be exported as raw bytes")
        }
        return Data(bytes.map { $0! })
    }
}

public struct ScanResult: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let regionID: UUID
    public let regionName: String
    public let offset: Int
    public let dataType: MemoryDataType
    public let initialValue: MemoryValue?
    public var previousValue: MemoryValue?
    public var currentValue: MemoryValue?
    public var observedAt: Date

    public init(
        id: String? = nil,
        regionID: UUID,
        regionName: String,
        offset: Int,
        dataType: MemoryDataType,
        initialValue: MemoryValue?,
        previousValue: MemoryValue?,
        currentValue: MemoryValue?,
        observedAt: Date = Date()
    ) {
        self.id = id ?? "\(regionID.uuidString):\(offset):\(dataType.rawValue)"
        self.regionID = regionID
        self.regionName = regionName
        self.offset = offset
        self.dataType = dataType
        self.initialValue = initialValue
        self.previousValue = previousValue
        self.currentValue = currentValue
        self.observedAt = observedAt
    }

    public init(regionID: UUID, regionName: String, offset: Int, dataType: MemoryDataType, value: MemoryValue) {
        id = "\(regionID.uuidString):\(offset):\(dataType.rawValue)"
        self.regionID = regionID
        self.regionName = regionName
        self.offset = offset
        self.dataType = dataType
        initialValue = value
        previousValue = nil
        currentValue = value
        observedAt = Date()
    }
}

public struct ScanProgress: Sendable {
    public let processed: Int
    public let total: Int
    public let matches: Int
}