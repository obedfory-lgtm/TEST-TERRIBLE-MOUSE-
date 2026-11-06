import Foundation
import XCTest
@testable import MemoryEngine

final class MemoryEngineTests: XCTestCase {
    func testSignedAndUnsignedTypesRespectEndianness() throws {
        let littleEndian = Data([0xFE, 0xFF])
        let bigEndian = Data([0xFF, 0xFE])
        XCTAssertEqual(try MemoryDataType.int16.decode(littleEndian, byteOrder: .littleEndian), .signed(-2))
        XCTAssertEqual(try MemoryDataType.int16.decode(bigEndian, byteOrder: .bigEndian), .signed(-2))
        XCTAssertEqual(try MemoryDataType.uint16.decode(littleEndian, byteOrder: .littleEndian), .unsigned(65_534))
    }

    func testEveryIntegerWidthRoundTrips() throws {
        let cases: [(MemoryDataType, String, MemoryValue)] = [
            (.int8, "-128", .signed(-128)),
            (.uint8, "255", .unsigned(255)),
            (.int16, "-32768", .signed(-32_768)),
            (.uint16, "65535", .unsigned(65_535)),
            (.int32, "-2147483648", .signed(-2_147_483_648)),
            (.uint32, "4294967295", .unsigned(4_294_967_295)),
            (.int64, "-9223372036854775808", .signed(Int64.min)),
            (.uint64, "18446744073709551615", .unsigned(UInt64.max))
        ]
        for (type, input, expected) in cases {
            XCTAssertEqual(try type.decode(type.encode(input)), expected, type.displayName)
        }
    }

    func testProviderReadsLiveAuthorizedBuffer() async throws {
        let registry = MemoryRegionRegistry()
        let info = try await registry.register(
            name: "provider-backed",
            byteCount: 3,
            access: RegisteredBufferAccess(read: { range in
                Data([0x10, 0x20, 0x30][range])
            })
        )
        let snapshots = try await registry.snapshots()
        let snapshot = snapshots.first
        XCTAssertEqual(snapshot?.info.id, info.id)
        XCTAssertEqual(snapshot?.bytes, Data([0x10, 0x20, 0x30]))
    }

    func testRegistrationAndReadsRespectBoundsAndTotalLimit() async throws {
        let registry = MemoryRegionRegistry(maximumRegionSize: 4, maximumTotalBytes: 4)
        let region = try await registry.register(name: "bounded", bytes: Data([1, 2, 3]))
        do {
            _ = try await registry.register(name: "too-large-total", bytes: Data([4, 5]))
            XCTFail("The registry exceeded its configured total byte limit.")
        } catch MemoryEngineError.regionLimitExceeded {
        }
        do {
            _ = try await registry.read(region: region.id, range: 0..<4)
            XCTFail("The registry returned bytes outside the region.")
        } catch MemoryEngineError.invalidRange {
        }
    }

    func testLiveMonitorPublishesAndStops() async throws {
        let registry = MemoryRegionRegistry()
        _ = try await registry.register(name: "watched", bytes: Data([1]))
        let monitor = LiveValueMonitor(maximumHistory: 5)
        let stream = try await monitor.start(registry: registry, interval: 0.1)
        var iterator = stream.makeAsyncIterator()
        let observation = try await iterator.next()
        XCTAssertEqual(observation?.kind, .newSample)
        await monitor.pause()
        await monitor.resume()
        await monitor.stop()
    }

    func testFloat32EncodingAndTolerance() throws {
        let encoded = try MemoryDataType.float32.encode("1.25")
        let decoded = try MemoryDataType.float32.decode(encoded)
        XCTAssertEqual(decoded.compared(to: .floating(1.2500001), tolerance: 0.000001), .orderedSame)
        XCTAssertEqual(
            try MemoryDataType.float64.decode(MemoryDataType.float64.encode("-3.5")),
            .floating(-3.5)
        )
    }

    func testUTF16ByteOrder() throws {
        let little = try MemoryDataType.utf16.encode("A", byteOrder: .littleEndian)
        let big = try MemoryDataType.utf16.encode("A", byteOrder: .bigEndian)
        XCTAssertEqual(little, Data([0x41, 0x00]))
        XCTAssertEqual(big, Data([0x00, 0x41]))
        XCTAssertEqual(try MemoryDataType.utf16.decode(big, byteOrder: .bigEndian), .text("A"))
    }

    func testWildcardPattern() throws {
        let pattern = try BytePattern.parse("AA ?? 4F 10")
        XCTAssertTrue(pattern.matches(Data([0xAA, 0x01, 0x4F, 0x10]), at: 0))
        XCTAssertFalse(pattern.matches(Data([0xAA, 0x01, 0x4E, 0x10]), at: 0))
    }

    func testBytePatternAndStringScans() async throws {
        let registry = MemoryRegionRegistry()
        _ = try await registry.register(name: "strings", bytes: Data("hello world".utf8))
        let scanner = MemoryScanner()
        let byteMatches = try await scanner.scanBytes(
            regions: try await registry.snapshots(),
            pattern: BytePattern.parse("68 65 ?? 6C")
        )
        XCTAssertEqual(byteMatches.first?.offset, 0)

        let textMatches = try await scanner.scanStrings(
            regions: try await registry.snapshots(),
            target: "world",
            encoding: .utf8,
            byteLength: 5,
            mode: .exact
        )
        XCTAssertEqual(textMatches.first?.offset, 6)
    }

    func testRegistryEnforcesReadOnlyRegistration() async throws {
        let registry = MemoryRegionRegistry()
        let region = try await registry.register(name: "owned-buffer", bytes: Data([1, 2, 3]))
        let readBytes = try await registry.read(region: region.id, range: 0..<2)
        XCTAssertEqual(readBytes, Data([1, 2]))
        do {
            try await registry.write(region: region.id, range: 0..<1, bytes: Data([9]))
            XCTFail("A read-only region accepted a write.")
        } catch MemoryEngineError.readOnlyRegion(_) {
        }
    }

    func testNextScanRefinesExistingCandidates() async throws {
        let registry = MemoryRegionRegistry()
        let regionID = UUID()
        _ = try await registry.register(
            name: "values",
            bytes: Data([5, 0, 0, 0, 8, 0, 0, 0]),
            writable: true,
            id: regionID
        )
        let scanner = MemoryScanner()
        let first = try await scanner.firstScan(
            regions: try await registry.snapshots(),
            type: .int32,
            criterion: .unknown
        )
        XCTAssertEqual(first.count, 2)

        try await registry.write(region: regionID, range: 0..<4, bytes: Data([6, 0, 0, 0]))
        let refined = try await scanner.nextScan(
            regions: try await registry.snapshots(),
            criterion: .increased
        )
        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined.first?.currentValue, .signed(6))
        XCTAssertEqual(refined.first?.previousValue, .signed(5))
    }

    func testAlignmentResultLimitAndCancellation() async throws {
        let registry = MemoryRegionRegistry()
        _ = try await registry.register(name: "unaligned", bytes: Data([1, 0, 0, 0]))
        let snapshots = try await registry.snapshots()
        let scanner = MemoryScanner()
        let natural = try await scanner.firstScan(
            regions: snapshots,
            type: .uint16,
            criterion: .exact("0")
        )
        XCTAssertEqual(natural.map(\.offset), [2])
        let everyByte = try await scanner.firstScan(
            regions: snapshots,
            type: .uint16,
            criterion: .exact("0"),
            alignment: .everyByte
        )
        XCTAssertEqual(everyByte.map(\.offset), [1, 2])

        let truncated = try await scanner.firstScan(
            regions: snapshots,
            type: .uint8,
            criterion: .unknown,
            resultLimit: 1
        )
        XCTAssertEqual(truncated.count, 1)
        let wasTruncated = await scanner.resultsWereTruncated()
        XCTAssertTrue(wasTruncated)
        do {
            _ = try await scanner.firstScan(
                regions: snapshots,
                type: .uint8,
                criterion: .unknown,
                cancellation: { true }
            )
            XCTFail("Cancelled scan unexpectedly completed.")
        } catch is CancellationError {
        }
    }

    func testTextDecodingRejectsMalformedUTF8() throws {
        XCTAssertThrowsError(try MemoryDataType.utf8.decode(Data([0xC3, 0x28])))
        XCTAssertEqual(try MemoryDataType.utf8.decode(Data("hello".utf8)), .text("hello"))
    }

    func testSnapshotChecksumAndComparison() async throws {
        let registry = MemoryRegionRegistry()
        let id = UUID()
        _ = try await registry.register(name: "sample", bytes: Data([1, 2, 3]), writable: true, id: id)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SnapshotStore(directory: directory)
        let first = try await store.capture(name: "first", regions: try await registry.snapshots())
        try await registry.write(region: id, range: 1..<2, bytes: Data([9]))
        let second = try await store.capture(name: "second", regions: try await registry.snapshots())
        XCTAssertNotEqual(first.checksum, second.checksum)
        let differences = try await store.compare(first.id, to: second.id)
        XCTAssertEqual(differences.filter { $0.kind == .changed }.map(\.offset), [1])
        XCTAssertEqual(differences.filter { $0.kind == .unchanged }.map(\.offset), [0, 2])
        let restoredStore = SnapshotStore(directory: directory)
        try await restoredStore.restore()
        let restoredSnapshots = await restoredStore.list()
        XCTAssertEqual(restoredSnapshots.count, 2)
        try await restoredStore.deleteAll()
    }

    func testSessionPersistenceStoresMetadataWithoutRawBuffers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SessionStore(directory: directory)
        let session = DiagnosticSession(name: "unit-test", selectedTypes: [.int32], filters: ["region": "owned"])
        try await store.save(session)
        let restored = try await store.load(session.id)
        let sessions = try await store.list()
        XCTAssertEqual(restored.filters["region"], "owned")
        XCTAssertEqual(sessions.map(\.id), [session.id])
        try await store.deleteAll()
    }

    func testCustomExportFilenameAndNumberedConflict() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = ExportManager()
        let first = try manager.export(
            payload: ExportPayload(),
            filename: "session_06",
            format: .json,
            directory: directory
        )
        let second = try manager.export(
            payload: ExportPayload(),
            filename: "session_06",
            format: .json,
            directory: directory,
            existingFilePolicy: .numberedCopy
        )
        XCTAssertEqual(first.url.lastPathComponent, "session_06.json")
        XCTAssertEqual(second.url.lastPathComponent, "session_06_2.json")
        XCTAssertGreaterThan(first.byteCount, 0)
    }

    func testZipExportHasValidLocalFileSignature() throws {
        let data = try ExportManager().serializedData(payload: ExportPayload(), format: .zip)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
    }
}
