import Foundation

public enum MemoryEngineError: Error, LocalizedError, Equatable {
    case regionNotRegistered(UUID)
    case regionAlreadyRegistered(UUID)
    case regionLimitExceeded
    case snapshotNotFound(UUID)
    case snapshotLimitExceeded
    case monitorAlreadyRunning
    case invalidRange
    case readOnlyRegion(String)
    case invalidValue(String)
    case incompatibleValues
    case invalidPattern(String)
    case invalidFilename
    case fileAlreadyExists(URL)
    case unsupportedFormat(String)
    case invalidEncoding

    public var errorDescription: String? {
        switch self {
        case .regionNotRegistered(let id): "Region \(id.uuidString) is not registered."
        case .regionAlreadyRegistered(let id): "Region \(id.uuidString) is already registered."
        case .regionLimitExceeded: "The configured registered-region memory limit would be exceeded."
        case .snapshotNotFound(let id): "Snapshot \(id.uuidString) was not found."
        case .snapshotLimitExceeded: "The configured snapshot storage limit would be exceeded."
        case .monitorAlreadyRunning: "A live observation is already running."
        case .invalidRange: "The requested byte range is outside the registered region."
        case .readOnlyRegion(let name): "Region \(name) is read-only."
        case .invalidValue(let value): "The value “\(value)” is invalid for the selected data type."
        case .incompatibleValues: "The values cannot be compared."
        case .invalidPattern(let pattern): "The byte pattern “\(pattern)” is invalid."
        case .invalidFilename: "The filename contains unsupported characters."
        case .fileAlreadyExists(let url): "A file already exists at \(url.lastPathComponent)."
        case .unsupportedFormat(let format): "The \(format) export format is unsupported."
        case .invalidEncoding: "The bytes are not valid for the selected text encoding."
        }
    }
}

public enum ByteOrder: String, Codable, CaseIterable, Equatable, Sendable {
    case littleEndian
    case bigEndian
}

public enum MemoryDataType: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
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

    public var isNumeric: Bool {
        switch self {
        case .int8, .uint8, .int16, .uint16, .int32, .uint32, .int64, .uint64,
             .float32, .float64, .boolean:
            true
        case .utf8, .utf16, .ascii, .bytes:
            false
        }
    }

    public func decode(_ data: Data, byteOrder: ByteOrder = .littleEndian) throws -> MemoryValue {
        guard let width, data.count >= width else {
            switch self {
            case .utf8:
                guard let value = String(data: data, encoding: .utf8) else { throw MemoryEngineError.invalidEncoding }
                return .text(value)
            case .utf16:
                let encoding: String.Encoding = byteOrder == .littleEndian ? .utf16LittleEndian : .utf16BigEndian
                guard let value = String(data: data, encoding: encoding) else { throw MemoryEngineError.invalidEncoding }
                return .text(value)
            case .ascii:
                guard let value = String(data: data, encoding: .ascii) else { throw MemoryEngineError.invalidEncoding }
                return .text(value)
            case .bytes:
                return .bytes(Array(data))
            default:
                throw MemoryEngineError.invalidRange
            }
        }

        let raw = Self.unsignedValue(data.prefix(width), byteOrder: byteOrder)
        switch self {
        case .int8: return .signed(Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: raw))))
        case .uint8: return .unsigned(UInt64(UInt8(truncatingIfNeeded: raw)))
        case .int16:
            return .signed(Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: raw))))
        case .uint16: return .unsigned(UInt64(UInt16(truncatingIfNeeded: raw)))
        case .int32:
            return .signed(Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw))))
        case .uint32: return .unsigned(UInt64(UInt32(truncatingIfNeeded: raw)))
        case .int64: return .signed(Int64(bitPattern: raw))
        case .uint64: return .unsigned(raw)
        case .float32: return .floating(Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))))
        case .float64: return .floating(Double(bitPattern: raw))
        case .boolean: return .boolean(raw != 0)
        case .utf8, .utf16, .ascii, .bytes:
            throw MemoryEngineError.invalidRange
        }
    }

    public func encode(_ value: String, byteOrder: ByteOrder = .littleEndian) throws -> Data {
        guard let width else {
            switch self {
            case .utf8: return Data(value.utf8)
            case .utf16:
                let units = value.utf16
                var bytes = Data()
                for unit in units {
                    let ordered = byteOrder == .littleEndian ? unit.littleEndian : unit.bigEndian
                    withUnsafeBytes(of: ordered) { bytes.append(contentsOf: $0) }
                }
                return bytes
            case .ascii:
                guard let data = value.data(using: .ascii) else { throw MemoryEngineError.invalidValue(value) }
                return data
            case .bytes: return try BytePattern.parse(value).data()
            default: throw MemoryEngineError.invalidValue(value)
            }
        }

        let raw: UInt64
        switch self {
        case .int8:
            guard let number = Int8(value) else { throw MemoryEngineError.invalidValue(value) }
            raw = UInt64(UInt8(bitPattern: number))
        case .uint8:
            guard let number = UInt8(value) else { throw MemoryEngineError.invalidValue(value) }
            raw = UInt64(number)
        case .int16:
            guard let number = Int16(value) else { throw MemoryEngineError.invalidValue(value) }
            raw = UInt64(UInt16(bitPattern: number))
        case .uint16:
            guard let number = UInt16(value) else { throw MemoryEngineError.invalidValue(value) }
            raw = UInt64(number)
        case .int32:
            guard let number = Int32(value) else { throw MemoryEngineError.invalidValue(value) }
            raw = UInt64(UInt32(bitPattern: number))
        case .uint32:
            guard let number = UInt32(value) else { throw MemoryEngineError.invalidValue(value) }
            raw = UInt64(number)
        case .int64:
            guard let number = Int64(value) else { throw MemoryEngineError.invalidValue(value) }
            raw = UInt64(bitPattern: number)
        case .uint64:
            guard let number = UInt64(value) else { throw MemoryEngineError.invalidValue(value) }
            raw = number
        case .float32:
            guard let number = Float(value), number.isFinite else { throw MemoryEngineError.invalidValue(value) }
            raw = UInt64(number.bitPattern)
        case .float64:
            guard let number = Double(value), number.isFinite else { throw MemoryEngineError.invalidValue(value) }
            raw = number.bitPattern
        case .boolean:
            guard ["true", "false", "1", "0"].contains(value.lowercased()) else {
                throw MemoryEngineError.invalidValue(value)
            }
            raw = ["true", "1"].contains(value.lowercased()) ? 1 : 0
        case .utf8, .utf16, .ascii, .bytes:
            throw MemoryEngineError.invalidValue(value)
        }

        var result = Data()
        for index in 0..<width {
            let shiftIndex = byteOrder == .littleEndian ? index : width - index - 1
            result.append(UInt8(truncatingIfNeeded: raw >> (shiftIndex * 8)))
        }
        return result
    }

    private static func unsignedValue<S: Collection>(_ bytes: S, byteOrder: ByteOrder) -> UInt64 where S.Element == UInt8 {
        switch byteOrder {
        case .littleEndian:
            return bytes.enumerated().reduce(UInt64(0)) { partial, item in
                partial | (UInt64(item.element) << (item.offset * 8))
            }
        case .bigEndian:
            return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
    }
}

public enum MemoryValue: Equatable, Sendable, CustomStringConvertible {
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
            lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.unsigned(let lhs), .unsigned(let rhs)):
            lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.floating(let lhs), .floating(let rhs)):
            guard lhs.isFinite, rhs.isFinite else { return nil }
            if abs(lhs - rhs) <= tolerance { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        case (.boolean(let lhs), .boolean(let rhs)):
            lhs == rhs ? .orderedSame : (lhs == false ? .orderedAscending : .orderedDescending)
        case (.text(let lhs), .text(let rhs)):
            lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        default:
            nil
        }
    }
}

public struct BytePattern: Sendable, Equatable {
    public let bytes: [UInt8?]

    public init(bytes: [UInt8?]) {
        self.bytes = bytes
    }

    public static func parse(_ source: String) throws -> BytePattern {
        let components = source.split(whereSeparator: \.isWhitespace)
        guard !components.isEmpty else { throw MemoryEngineError.invalidPattern(source) }
        let bytes = try components.map { token -> UInt8? in
            if token == "??" { return nil }
            guard token.count == 2, let value = UInt8(token, radix: 16) else {
                throw MemoryEngineError.invalidPattern(source)
            }
            return value
        }
        return BytePattern(bytes: bytes)
    }

    public func matches(_ data: Data, at offset: Int) -> Bool {
        guard offset >= 0, offset + bytes.count <= data.count else { return false }
        return bytes.enumerated().allSatisfy { index, expected in
            expected == nil || expected == data[data.startIndex + offset + index]
        }
    }

    public func data() -> Data {
        Data(bytes.map { $0 ?? 0 })
    }
}
