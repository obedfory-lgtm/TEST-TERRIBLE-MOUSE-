import Foundation
import MemoryEngine

enum DiagnosticHostSampleData {
    static let numericRegionID = UUID()
    static let textRegionID = UUID()
    static let binaryRegionID = UUID()

    static func register(in registry: MemoryRegionRegistry) async throws {
        let currentRegions = await registry.regions()
        let currentIDs = Set(currentRegions.map(\.id))
        if !currentIDs.contains(numericRegionID) {
            let values = [Int32(100), 250, 1_024, -5]
            var bytes = Data()
            for value in values {
                bytes.append(try MemoryDataType.int32.encode(String(value)))
            }
            try await registry.register(
                name: "Sample numeric values",
                bytes: bytes,
                writable: true,
                dataType: .int32,
                id: numericRegionID
            )
        }
        if !currentIDs.contains(textRegionID) {
            try await registry.register(
                name: "Sample text",
                bytes: Data("Memory Studio sample buffer".utf8),
                dataType: .utf8,
                id: textRegionID
            )
        }
        if !currentIDs.contains(binaryRegionID) {
            try await registry.register(
                name: "Sample binary pattern",
                bytes: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x10, 0x20, 0xAA, 0x55]),
                dataType: .bytes,
                id: binaryRegionID
            )
        }
    }

    static func incrementFirstValue(in registry: MemoryRegionRegistry) async throws {
        let current = try await registry.read(region: numericRegionID, range: 0..<4)
        guard case .signed(let value) = try MemoryDataType.int32.decode(current) else {
            throw MemoryEngineError.invalidValue("numeric sample buffer")
        }
        let (nextValue, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw MemoryEngineError.invalidValue("numeric sample overflow") }
        try await registry.write(
            region: numericRegionID,
            range: 0..<4,
            bytes: MemoryDataType.int32.encode(String(nextValue))
        )
    }
}
