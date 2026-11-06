import CryptoKit
import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
    case txt, json, csv, bin, hex, xml, md, zip
    public var id: String { rawValue }
}

public enum ExistingFilePolicy: Sendable { case replace, numberedCopy, fail }

public struct ExportOptions: Sendable {
    public var includeMetadata = true
    public var includeTimestamps = true
    public var includePreviousValues = true
    public var includeRegionInformation = true
    public var includeRawBytes = false
    public var includeObservations = false
    public init() {}
}

public struct ExportPayload: Sendable {
    public var results: [ScanResult]
    public var snapshots: [MemorySnapshot]
    public var observations: [ValueObservation]
    public init(results: [ScanResult] = [], snapshots: [MemorySnapshot] = [], observations: [ValueObservation] = []) {
        self.results = results
        self.snapshots = snapshots
        self.observations = observations
    }
}

public struct ExportReceipt: Sendable {
    public let url: URL
    public let byteCount: Int
    public let sha256: String
}

public struct ExportManager {
    public init() {}

    public func serializedData(payload: ExportPayload, format: ExportFormat, options: ExportOptions = ExportOptions()) throws -> Data {
        switch format {
        case .json: return try jsonData(payload, options: options)
        case .csv: return Data(csv(payload, options: options).utf8)
        case .txt, .md: return Data(text(payload, options: options, markdown: format == .md).utf8)
        case .xml: return Data(xml(payload, options: options).utf8)
        case .hex:
            let data = Data(payload.snapshots.flatMap { $0.regions.flatMap(\.bytes) })
            return Data(hexDump(data).utf8)
        case .bin:
            guard options.includeRawBytes else { throw MemoryEngineError.unsupportedFormat("BIN without raw-byte inclusion") }
            return Data(payload.snapshots.flatMap { $0.regions.flatMap(\.bytes) })
        case .zip:
            var files = [("report.json", try jsonData(payload, options: options))]
            if options.includeObservations, !payload.observations.isEmpty {
                files.append(("observations.json", try JSONEncoder().encode(payload.observations)))
            }
            if options.includeRawBytes {
                for snapshot in payload.snapshots {
                    for region in snapshot.regions {
                        files.append(("snapshots/\(snapshot.id.uuidString)/\(region.regionID.uuidString).bin", region.bytes))
                    }
                }
            }
            return try storedZip(files)
        }
    }

    public func export(
        payload: ExportPayload,
        filename: String,
        format: ExportFormat,
        directory: URL,
        options: ExportOptions = ExportOptions(),
        conflict: ExistingFilePolicy = .fail
    ) throws -> ExportReceipt {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MemoryEngineError.invalidFilename
        }
        let suffix = ".\(format.rawValue)"
        let base = trimmed.lowercased().hasSuffix(suffix) ? String(trimmed.dropLast(suffix.count)) : trimmed
        guard !base.isEmpty else { throw MemoryEngineError.invalidFilename }
        let requested = directory.appendingPathComponent(base).appendingPathExtension(format.rawValue)
        let target = try resolve(requested, conflict: conflict)
        let data = try serializedData(payload: payload, format: format, options: options)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        guard let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == data.count else {
            throw CocoaError(.fileWriteUnknown)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ExportReceipt(url: target, byteCount: size, sha256: hash)
    }

    private func resolve(_ url: URL, conflict: ExistingFilePolicy) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        switch conflict {
        case .replace: return url
        case .fail: throw MemoryEngineError.fileAlreadyExists(url.lastPathComponent)
        case .numberedCopy:
            var number = 2
            while number < Int.max {
                let candidate = url.deletingPathExtension().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_\(number)")
                    .appendingPathExtension(url.pathExtension)
                if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                number += 1
            }
            throw MemoryEngineError.invalidFilename
        }
    }

    private func jsonData(_ payload: ExportPayload, options: ExportOptions) throws -> Data {
        let results = payload.results.map { result in
            ExportResultRecord(
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
        let snapshots = payload.snapshots.map { snapshot in
            ExportSnapshotRecord(
                id: snapshot.id.uuidString,
                name: snapshot.name,
                createdAt: options.includeTimestamps ? snapshot.createdAt : nil,
                checksum: snapshot.checksum,
                regions: snapshot.regions.map {
                    ExportRegionRecord(
                        id: options.includeRegionInformation ? $0.regionID.uuidString : nil,
                        name: options.includeRegionInformation ? $0.regionName : nil,
                        byteCount: $0.byteCount,
                        bytes: options.includeRawBytes ? $0.bytes.base64EncodedString() : nil
                    )
                }
            )
        }
        let envelope = ExportEnvelope(
            generatedAt: options.includeMetadata && options.includeTimestamps ? Date() : nil,
            results: results,
            snapshots: snapshots,
            observations: options.includeObservations ? payload.observations.map {
                ExportObservationRecord(
                    timestamp: options.includeTimestamps ? $0.timestamp : nil,
                    regionID: options.includeRegionInformation ? $0.regionID.uuidString : nil,
                    region: options.includeRegionInformation ? $0.regionName : nil,
                    changedByteCount: $0.changedByteCount,
                    kind: $0.kind.rawValue
                )
            } : []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    private func csv(_ payload: ExportPayload, options: ExportOptions) -> String {
        var lines = ["id,region,offset,type,current,previous,timestamp"]
        let formatter = ISO8601DateFormatter()
        for result in payload.results {
            let fields = [
                result.id,
                options.includeRegionInformation ? result.regionName : "",
                String(result.offset),
                result.dataType.rawValue,
                result.currentValue?.description ?? "",
                options.includePreviousValues ? result.previousValue?.description ?? "" : "",
                options.includeTimestamps ? formatter.string(from: result.observedAt) : ""
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        if options.includeObservations {
            for observation in payload.observations {
                let fields = [
                    "observation:\(observation.id.uuidString)",
                    options.includeRegionInformation ? observation.regionName : "",
                    "",
                    "observation:\(observation.kind.rawValue)",
                    "\(observation.changedByteCount) changed bytes",
                    "",
                    options.includeTimestamps ? formatter.string(from: observation.timestamp) : ""
                ]
                lines.append(fields.map(csvEscape).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func text(_ payload: ExportPayload, options: ExportOptions, markdown: Bool) -> String {
        var lines = [markdown ? "# Memory Studio diagnostic report" : "Memory Studio diagnostic report"]
        if options.includeMetadata {
            lines.append("Results: \(payload.results.count)")
            lines.append("Snapshots: \(payload.snapshots.count)")
            if options.includeTimestamps { lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))") }
        }
        for result in payload.results {
            let region = options.includeRegionInformation ? "\(result.regionName) " : ""
            let previous = options.includePreviousValues ? " | previous: \(result.previousValue?.description ?? "-")" : ""
            lines.append("\(region)+0x\(String(result.offset, radix: 16).uppercased()) \(result.dataType.displayName): \(result.currentValue?.description ?? "-")\(previous)")
        }
        for snapshot in payload.snapshots {
            lines.append("Snapshot \(snapshot.name): \(snapshot.capturedByteCount) bytes, SHA-256 \(snapshot.checksum)")
        }
        if options.includeObservations {
            for observation in payload.observations {
                lines.append("Observation \(observation.regionName): \(observation.kind.rawValue), \(observation.changedByteCount) changed bytes")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func xml(_ payload: ExportPayload, options: ExportOptions) -> String {
        let rows = payload.results.map { result in
            let region = options.includeRegionInformation ? " region=\"\(xmlEscape(result.regionName))\"" : ""
            let previous = options.includePreviousValues ? " previous=\"\(xmlEscape(result.previousValue?.description ?? ""))\"" : ""
            let timestamp = options.includeTimestamps ? " timestamp=\"\(ISO8601DateFormatter().string(from: result.observedAt))\"" : ""
            return "<result id=\"\(xmlEscape(result.id))\" offset=\"\(result.offset)\" type=\"\(result.dataType.rawValue)\"\(region)\(timestamp)><value\(previous)>\(xmlEscape(result.currentValue?.description ?? ""))</value></result>"
        }.joined()
        let observationRows = options.includeObservations ? payload.observations.map { observation in
            let region = options.includeRegionInformation ? " region=\"\(xmlEscape(observation.regionName))\"" : ""
            let timestamp = options.includeTimestamps ? " timestamp=\"\(ISO8601DateFormatter().string(from: observation.timestamp))\"" : ""
            return "<observation kind=\"\(observation.kind.rawValue)\" changedBytes=\"\(observation.changedByteCount)\"\(region)\(timestamp)/>"
        }.joined() : ""
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><diagnostics>\(rows)\(observationRows)</diagnostics>"
    }

    private func hexDump(_ data: Data) -> String {
        stride(from: 0, to: data.count, by: 16).map { offset in
            let chunk = data[offset..<min(offset + 16, data.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(decoding: chunk.map { (0x20...0x7E).contains($0) ? $0 : 0x2E }, as: UTF8.self)
            return String(format: "%08X  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
        }.joined(separator: "\n") + (data.isEmpty ? "" : "\n")
    }

    private func csvEscape(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }

    private func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func storedZip(_ files: [(String, Data)]) throws -> Data {
        guard files.count <= Int(UInt16.max) else { throw MemoryEngineError.unsupportedFormat("ZIP entry count") }
        var archive = Data()
        var central = Data()
        for (path, contents) in files {
            let name = Data(path.utf8)
            guard name.count <= Int(UInt16.max), contents.count <= Int(UInt32.max), archive.count <= Int(UInt32.max) else {
                throw MemoryEngineError.unsupportedFormat("ZIP32 size limit")
            }
            let checksum = crc32(contents)
            let offset = UInt32(archive.count)
            archive.appendLE(UInt32(0x04034B50)); archive.appendLE(UInt16(20)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(checksum); archive.appendLE(UInt32(contents.count)); archive.appendLE(UInt32(contents.count))
            archive.appendLE(UInt16(name.count)); archive.appendLE(UInt16(0)); archive.append(name); archive.append(contents)
            central.appendLE(UInt32(0x02014B50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(checksum); central.appendLE(UInt32(contents.count)); central.appendLE(UInt32(contents.count))
            central.appendLE(UInt16(name.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(offset); central.append(name)
        }
        guard archive.count <= Int(UInt32.max), central.count <= Int(UInt32.max) else {
            throw MemoryEngineError.unsupportedFormat("ZIP32 size limit")
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.appendLE(UInt32(0x06054B50)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(files.count)); archive.appendLE(UInt16(files.count))
        archive.appendLE(UInt32(central.count)); archive.appendLE(centralOffset); archive.appendLE(UInt16(0))
        return archive
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
        }
        return crc ^ UInt32.max
    }
}

private struct ExportEnvelope: Encodable {
    let generatedAt: Date?
    let results: [ExportResultRecord]
    let snapshots: [ExportSnapshotRecord]
    let observations: [ExportObservationRecord]
}

private struct ExportResultRecord: Encodable {
    let id: String
    let regionID: String?
    let region: String?
    let offset: Int
    let type: String
    let current: String?
    let previous: String?
    let timestamp: Date?
}

private struct ExportSnapshotRecord: Encodable {
    let id: String
    let name: String
    let createdAt: Date?
    let checksum: String
    let regions: [ExportRegionRecord]
}

private struct ExportRegionRecord: Encodable {
    let id: String?
    let name: String?
    let byteCount: Int
    let bytes: String?
}

private struct ExportObservationRecord: Encodable {
    let timestamp: Date?
    let regionID: String?
    let region: String?
    let changedByteCount: Int
    let kind: String
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        for byte in 0..<MemoryLayout<T>.size { append(UInt8(truncatingIfNeeded: value.littleEndian >> (byte * 8))) }
    }
}