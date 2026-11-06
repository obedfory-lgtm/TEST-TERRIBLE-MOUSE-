import CryptoKit
import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Equatable, Sendable {
    case txt, json, csv, bin, hex, xml, markdown, zip
    public var id: String { rawValue }
    public var fileExtension: String { self == .markdown ? "md" : rawValue }
}

public enum ExistingFilePolicy: Sendable {
    case replace
    case numberedCopy
    case fail
}

public struct ExportOptions: Sendable {
    public var includeMetadata = true
    public var includeTimestamps = true
    public var includePreviousValues = true
    public var includeRegionInformation = true
    public var includeRawBytes = false

    public init() {}
}

public struct ExportPayload: Sendable {
    public var results: [ScanResult]
    public var snapshots: [MemorySnapshot]

    public init(results: [ScanResult] = [], snapshots: [MemorySnapshot] = []) {
        self.results = results
        self.snapshots = snapshots
    }
}

public struct ExportReceipt: Sendable {
    public let url: URL
    public let byteCount: Int
    public let checksum: String
}

public struct ExportManager {
    public init() {}

    public func serializedData(
        payload: ExportPayload,
        format: ExportFormat,
        options: ExportOptions = ExportOptions()
    ) throws -> Data {
        try makeData(payload: payload, format: format, options: options)
    }

    public func export(
        payload: ExportPayload,
        filename: String,
        format: ExportFormat,
        directory: URL,
        options: ExportOptions = ExportOptions(),
        existingFilePolicy: ExistingFilePolicy = .fail
    ) throws -> ExportReceipt {
        let name = try safeFilename(filename)
        let expectedSuffix = ".\(format.fileExtension)"
        let baseName = name.lowercased().hasSuffix(expectedSuffix)
            ? String(name.dropLast(expectedSuffix.count))
            : name
        guard !baseName.isEmpty else { throw MemoryEngineError.invalidFilename }
        let initialURL = directory.appendingPathComponent(baseName).appendingPathExtension(format.fileExtension)
        let url = try resolveConflict(initialURL, policy: existingFilePolicy)
        let data = try serializedData(payload: payload, format: format, options: options)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        guard FileManager.default.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == data.count else {
            throw CocoaError(.fileWriteUnknown)
        }
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ExportReceipt(url: url, byteCount: data.count, checksum: checksum)
    }

    private func safeFilename(_ filename: String) throws -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MemoryEngineError.invalidFilename
        }
        return trimmed
    }

    private func resolveConflict(_ url: URL, policy: ExistingFilePolicy) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        switch policy {
        case .replace:
            return url
        case .fail:
            throw MemoryEngineError.fileAlreadyExists(url)
        case .numberedCopy:
            var index = 2
            while true {
                let baseURL = url.deletingPathExtension()
                let candidate = baseURL.deletingLastPathComponent()
                    .appendingPathComponent("\(baseURL.lastPathComponent)_\(index)")
                    .appendingPathExtension(url.pathExtension)
                if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                index += 1
            }
        }
    }

    private func makeData(
        payload: ExportPayload,
        format: ExportFormat,
        options: ExportOptions
    ) throws -> Data {
        switch format {
        case .json:
            let records = payload.results.map { result in
                ExportResult(
                    id: result.id,
                    regionID: options.includeRegionInformation ? result.regionID.uuidString : nil,
                    region: options.includeRegionInformation ? result.regionName : nil,
                    offset: result.offset,
                    type: result.dataType.rawValue,
                    current: result.currentValue?.description,
                    previous: options.includePreviousValues ? result.previousValue?.description : nil,
                    timestamp: options.includeTimestamps ? result.observedAt : nil
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(records)
        case .csv:
            var lines = ["id,region,offset,type,current,previous,timestamp"]
            lines += payload.results.map { result in
                [
                    result.id,
                    options.includeRegionInformation ? result.regionName : "",
                    String(result.offset),
                    result.dataType.rawValue,
                    result.currentValue?.description ?? "",
                    options.includePreviousValues ? result.previousValue?.description ?? "" : "",
                    options.includeTimestamps ? ISO8601DateFormatter().string(from: result.observedAt) : ""
                ].map(Self.csvEscape).joined(separator: ",")
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        case .txt, .markdown:
            var lines = [format == .markdown ? "# Diagnostic export" : "Diagnostic export"]
            if options.includeMetadata {
                lines.append("Created: \(ISO8601DateFormatter().string(from: Date()))")
                lines.append("Results: \(payload.results.count)")
            }
            for result in payload.results {
                let region = options.includeRegionInformation ? "\(result.regionName) " : ""
                let previous = options.includePreviousValues ? " | previous: \(result.previousValue?.description ?? "—")" : ""
                lines.append("\(region)+0x\(String(result.offset, radix: 16).uppercased()) \(result.dataType.displayName): \(result.currentValue?.description ?? "—")\(previous)")
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        case .hex:
            let bytes = payload.snapshots.flatMap { $0.regions.flatMap(\.bytes) }
            let text = stride(from: 0, to: bytes.count, by: 16).map { offset in
                let chunk = bytes[offset..<min(offset + 16, bytes.count)]
                return String(format: "%08X", offset) + "  " + chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            }.joined(separator: "\n")
            return Data(text.utf8)
        case .bin:
            guard options.includeRawBytes else { throw MemoryEngineError.unsupportedFormat("BIN requires raw bytes") }
            return Data(payload.snapshots.flatMap { $0.regions.flatMap(\.bytes) })
        case .zip:
            var files = [("results.json", try makeData(payload: payload, format: .json, options: options))]
            let metadata = payload.snapshots.map {
                SnapshotManifest(
                    id: $0.id.uuidString,
                    name: $0.name,
                    createdAt: $0.createdAt,
                    checksum: $0.checksum,
                    regions: $0.regions.map {
                        RegionManifest(id: $0.regionID.uuidString, name: $0.regionName, byteCount: $0.bytes.count)
                    }
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            files.append(("snapshots/manifest.json", try encoder.encode(metadata)))
            if options.includeRawBytes {
                for snapshot in payload.snapshots {
                    for region in snapshot.regions {
                        files.append((
                            "snapshots/\(snapshot.id.uuidString)/\(region.regionID.uuidString).bin",
                            region.bytes
                        ))
                    }
                }
            }
            return Self.makeStoredZip(files)
        case .xml:
            let rows = payload.results.map { result in
                "<result id=\"\(Self.xmlEscape(result.id))\" offset=\"\(result.offset)\" type=\"\(result.dataType.rawValue)\"><value>\(Self.xmlEscape(result.currentValue?.description ?? ""))</value></result>"
            }.joined()
            return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><diagnostics>\(rows)</diagnostics>".utf8)
        }
    }

    private static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func makeStoredZip(_ files: [(String, Data)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        for (path, contents) in files {
            let name = Data(path.utf8)
            let checksum = crc32(contents)
            let offset = UInt32(archive.count)
            archive.appendLE(UInt32(0x04034B50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(checksum)
            archive.appendLE(UInt32(contents.count))
            archive.appendLE(UInt32(contents.count))
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(0))
            archive.append(name)
            archive.append(contents)

            centralDirectory.appendLE(UInt32(0x02014B50))
            centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(checksum)
            centralDirectory.appendLE(UInt32(contents.count))
            centralDirectory.appendLE(UInt32(contents.count))
            centralDirectory.appendLE(UInt16(name.count))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt32(0))
            centralDirectory.appendLE(offset)
            centralDirectory.append(name)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendLE(UInt32(0x06054B50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(files.count))
        archive.appendLE(UInt16(files.count))
        archive.appendLE(UInt32(centralDirectory.count))
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ UInt32.max
    }
}

private struct ExportResult: Encodable {
    let id: String
    let regionID: String?
    let region: String?
    let offset: Int
    let type: String
    let current: String?
    let previous: String?
    let timestamp: Date?
}

private struct SnapshotManifest: Encodable {
    let id: String
    let name: String
    let createdAt: Date
    let checksum: String
    let regions: [RegionManifest]
}

private struct RegionManifest: Encodable {
    let id: String
    let name: String
    let byteCount: Int
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        let littleEndian = value.littleEndian
        for byte in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: littleEndian >> (byte * 8)))
        }
    }
}
