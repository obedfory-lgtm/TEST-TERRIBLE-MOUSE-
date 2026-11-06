import Foundation
import XCTest
@testable import MemoryStudio

final class MemoryStudioTests: XCTestCase {
    func testIntegerWidthsAndEndianness() throws {
        let cases: [(MemoryDataType, String, MemoryValue)] = [
            (.int8, "-128", .signed(-128)), (.uint8, "255", .unsigned(255)),
            (.int16, "-32768", .signed(-32_768)), (.uint16, "65535", .unsigned(65_535)),
            (.int32, "-2147483648", .signed(-2_147_483_648)), (.uint32, "4294967295", .unsigned(4_294_967_295)),
            (.int64, "-9223372036854775808", .signed(Int64.min)), (.uint64, "18446744073709551615", .unsigned(UInt64.max))
        ]
        for (type, input, expected) in cases {
            XCTAssertEqual(try type.decode(type.encode(input)), expected, type.displayName)
        }
        XCTAssertEqual(try MemoryDataType.int16.decode(Data([0xFF, 0xFE]), byteOrder: .bigEndian), .signed(-2))
        XCTAssertEqual(try MemoryDataType.uint32.decode(Data([0x78, 0x56, 0x34, 0x12])), .unsigned(0x12345678))
    }

    func testFloatingPointToleranceAndBoolean() throws {
        let encoded = try MemoryDataType.float32.encode("1.25")
        let decoded = try MemoryDataType.float32.decode(encoded)
        XCTAssertEqual(decoded.compared(to: .floating(1.2500002), tolerance: 0.000001), .orderedSame)
        XCTAssertEqual(try MemoryDataType.float64.decode(MemoryDataType.float64.encode("-3.5")), .floating(-3.5))
        XCTAssertEqual(try MemoryDataType.boolean.decode(Data([1])), .boolean(true))
    }

    func testUTF8UTF16AndInvalidEncoding() throws {
        XCTAssertEqual(try MemoryDataType.utf8.decode(Data("hello".utf8)), .text("hello"))
        XCTAssertEqual(try MemoryDataType.utf16.decode(Data([0x00, 0x41]), byteOrder: .bigEndian), .text("A"))
        XCTAssertThrowsError(try MemoryDataType.utf8.decode(Data([0xC3, 0x28])))
    }

    func testRegistryEnforcesOwnershipBoundsAndReadOnly() async throws {
        let registry = MemoryRegionRegistry(maximumRegionSize: 4, maximumTotalBytes: 4)
        let region = try await registry.register(name: "owned", bytes: Data([1, 2, 3]))
        let firstBytes = try await registry.read(region: region.id, range: 0..<2)
        XCTAssertEqual(firstBytes, Data([1, 2]))
        do {
            try await registry.write(region: region.id, range: 0..<1, bytes: Data([9]))
            XCTFail("Read-only registration accepted a write.")
        } catch MemoryEngineError.readOnlyRegion(_) { }
        do {
            _ = try await registry.read(region: region.id, range: 0..<4)
            XCTFail("Read outside the registered range succeeded.")
        } catch MemoryEngineError.invalidRange { }
        do {
            _ = try await registry.register(name: "over-limit", bytes: Data([4, 5]))
            XCTFail("The total registration limit was exceeded.")
        } catch MemoryEngineError.regionLimitExceeded { }
    }

    func testFirstScanRefinementAndCancellation() async throws {
        let registry = MemoryRegionRegistry()
        let id = UUID()
        var values = Data()
        for value in [5, 8, 11] { values.append(try MemoryDataType.int32.encode(String(value))) }
        _ = try await registry.register(name: "values", bytes: values, writable: true, dataType: .int32, id: id)
        let scanner = MemoryScanner()
        let initial = try await scanner.firstScan(regions: await registry.snapshots(), type: .int32, criterion: .unknown)
        XCTAssertEqual(initial.count, 3)
        try await registry.write(region: id, range: 0..<4, bytes: MemoryDataType.int32.encode("6"))
        let refined = try await scanner.nextScan(regions: await registry.snapshots(), criterion: .increased)
        XCTAssertEqual(refined.map(\.currentValue), [.signed(6)])
        XCTAssertEqual(refined.first?.previousValue, .signed(5))
        do {
            _ = try await scanner.firstScan(regions: await registry.snapshots(), type: .int8, criterion: .unknown, cancellation: { true })
            XCTFail("Cancelled scan completed.")
        } catch is CancellationError { }
    }

    func testRangeAndRelativeRefinementOperators() async throws {
        let registry = MemoryRegionRegistry()
        let regionID = UUID()
        var bytes = Data()
        for value in [10, 20, 30] { bytes.append(try MemoryDataType.int32.encode(String(value))) }
        _ = try await registry.register(name: "range-values", bytes: bytes, writable: true, dataType: .int32, id: regionID)
        let scanner = MemoryScanner()
        let inRange = try await scanner.firstScan(
            regions: await registry.snapshots(),
            type: .int32,
            criterion: .between("15", "25")
        )
        XCTAssertEqual(inRange.map(\.currentValue), [.signed(20)])
        try await registry.write(region: regionID, range: 4..<8, bytes: MemoryDataType.int32.encode("23"))
        let increased = try await scanner.nextScan(regions: await registry.snapshots(), criterion: .increasedBy("3"))
        XCTAssertEqual(increased.count, 1)
        try await registry.write(region: regionID, range: 4..<8, bytes: MemoryDataType.int32.encode("20"))
        let decreased = try await scanner.nextScan(regions: await registry.snapshots(), criterion: .decreasedBy("3"))
        XCTAssertEqual(decreased.count, 1)
        let sameAsInitial = try await scanner.nextScan(regions: await registry.snapshots(), criterion: .sameAsInitial)
        XCTAssertEqual(sameAsInitial.count, 1)
        try await registry.write(region: regionID, range: 4..<8, bytes: MemoryDataType.int32.encode("21"))
        let changed = try await scanner.nextScan(regions: await registry.snapshots(), criterion: .changed)
        XCTAssertEqual(changed.count, 1)
        let unchanged = try await scanner.nextScan(regions: await registry.snapshots(), criterion: .unchanged)
        XCTAssertEqual(unchanged.count, 1)
    }

    func testAlignmentAndResultBound() async throws {
        let registry = MemoryRegionRegistry()
        _ = try await registry.register(name: "aligned", bytes: Data([1, 0, 0, 0]))
        let snapshots = await registry.snapshots()
        let scanner = MemoryScanner(maximumResults: 1)
        let results = try await scanner.firstScan(regions: snapshots, type: .uint16, criterion: .exact("0"), alignment: .everyByte)
        XCTAssertEqual(results.count, 1)
        let truncated = await scanner.didTruncate()
        XCTAssertTrue(truncated)
    }

    func testWildcardBinaryAndStringSearch() async throws {
        let registry = MemoryRegionRegistry()
        _ = try await registry.register(name: "data", bytes: Data([0xAA, 0x10, 0x4F, 0xAA, 0x20, 0x4F] + Array("hello world".utf8)))
        let snapshots = await registry.snapshots()
        let scanner = MemoryScanner()
        let binary = try await scanner.scanBytes(regions: snapshots, pattern: BytePattern.parse("AA ?? 4F"))
        XCTAssertEqual(binary.map(\.offset), [0, 3])
        let text = try await scanner.scanStrings(regions: snapshots, target: "world", encoding: .utf8, byteLength: 5)
        XCTAssertEqual(text.map(\.offset), [12])
    }

    func testUTF16TextSearchAndInvalidWindowHandling() async throws {
        let registry = MemoryRegionRegistry()
        let wideText = try MemoryDataType.utf16.encode("AB")
        var source = wideText
        source.append(contentsOf: [0xC3, 0x28])
        _ = try await registry.register(name: "wide-text", bytes: source)
        let scanner = MemoryScanner()
        let matches = try await scanner.scanStrings(
            regions: await registry.snapshots(),
            target: "b",
            encoding: .utf16,
            byteLength: 2,
            mode: .exact,
            caseSensitive: false
        )
        XCTAssertEqual(matches.map(\.offset), [2])
        let invalidUTF8 = try await scanner.scanStrings(
            regions: await registry.snapshots(),
            target: "(",
            encoding: .utf8,
            byteLength: 2
        )
        XCTAssertTrue(invalidUTF8.isEmpty)
    }

    func testSnapshotIntegrityAndComparison() async throws {
        let registry = MemoryRegionRegistry()
        let id = UUID()
        _ = try await registry.register(name: "snapshot-region", bytes: Data([1, 2, 3]), writable: true, id: id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SnapshotStore(directory: folder)
        let before = try await store.capture(name: "before", regions: await registry.snapshots())
        try await registry.write(region: id, range: 1..<2, bytes: Data([9]))
        let after = try await store.capture(name: "after", regions: await registry.snapshots())
        XCTAssertNotEqual(before.checksum, after.checksum)
        let differences = try await store.compare(before.id, to: after.id)
        XCTAssertEqual(differences.map(\.offset), [1])
        try await store.rename(after.id, to: "renamed")
        try await store.delete(before.id)
    }

    func testSessionAndAllNamedExports() async throws {
        let result = ScanResult(regionID: UUID(), regionName: "owned", offset: 4, dataType: .uint8, value: .unsigned(7))
        let session = DiagnosticSession(name: "unit", selectedTypes: [.uint8], results: [result])
        let sessions = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try await sessions.save(session)
        let restored = try await sessions.load(session.id)
        XCTAssertEqual(restored.results.first?.offset, 4)
        XCTAssertEqual(restored.results.first?.currentValue, .unsigned(7))
        let restoredScanner = MemoryScanner()
        await restoredScanner.restoreCandidates(restored.results.map { record in
            ScanResult(
                id: record.id,
                regionID: record.regionID,
                regionName: record.regionName,
                offset: record.offset,
                dataType: record.type,
                initialValue: record.initialValue,
                previousValue: record.previousValue,
                currentValue: record.currentValue,
                observedAt: record.observedAt
            )
        })
        let restoredCandidates = await restoredScanner.results()
        XCTAssertEqual(restoredCandidates.count, 1)

        let manager = ExportManager()
        let snapshotRegion = SnapshotRegion(
            regionID: result.regionID,
            regionName: "owned",
            byteCount: 2,
            bytes: Data([0x12, 0x34])
        )
        let snapshot = MemorySnapshot(
            id: UUID(),
            name: "export-fixture",
            createdAt: Date(),
            regions: [snapshotRegion],
            checksum: "fixture-checksum"
        )
        let payload = ExportPayload(results: [result], snapshots: [snapshot])
        for format in ExportFormat.allCases {
            var options = ExportOptions()
            options.includeRawBytes = true
            XCTAssertFalse(try manager.serializedData(payload: payload, format: format, options: options).isEmpty, format.rawValue)
        }
        let observation = ValueObservation(id: UUID(), timestamp: Date(), regionID: result.regionID, regionName: "owned", changedByteCount: 1, kind: .changed)
        var observationOptions = ExportOptions()
        observationOptions.includeObservations = true
        let report = try manager.serializedData(
            payload: ExportPayload(results: [result], observations: [observation]),
            format: .json,
            options: observationOptions
        )
        XCTAssertTrue(String(decoding: report, as: UTF8.self).contains("changedByteCount"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = try manager.export(payload: payload, filename: "audit", format: .csv, directory: directory)
        let second = try manager.export(payload: payload, filename: "audit", format: .csv, directory: directory, conflict: .numberedCopy)
        XCTAssertEqual(first.url.lastPathComponent, "audit.csv")
        XCTAssertEqual(second.url.lastPathComponent, "audit_2.csv")
        XCTAssertGreaterThan(first.sha256.count, 50)
        XCTAssertThrowsError(try manager.export(payload: payload, filename: "../invalid", format: .json, directory: directory))
    }

    func testMonitorEmitsSampleAndStops() async throws {
        let registry = MemoryRegionRegistry()
        _ = try await registry.register(name: "observed", bytes: Data([1]))
        let monitor = LiveValueMonitor(maximumHistory: 4)
        let stream = try await monitor.start(registry: registry, interval: 0.1)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.kind, .newSample)
        await monitor.stop()
    }
}