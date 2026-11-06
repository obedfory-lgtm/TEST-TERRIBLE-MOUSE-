import Foundation

public enum FirstScanCriterion: Sendable {
    case exact(String)
    case greaterThan(String)
    case lessThan(String)
    case between(String, String)
    case unknown
    case bytes(BytePattern)
}

public enum NextScanCriterion: Equatable, Sendable {
    case exact(String)
    case greaterThan(String)
    case lessThan(String)
    case between(String, String)
    case increased
    case decreased
    case increasedBy(String)
    case decreasedBy(String)
    case changed
    case unchanged
    case sameAsInitial
}

public enum StringMatchMode: Sendable {
    case exact
    case prefix
    case suffix
    case substring
}

public enum MemoryScanAlignment: Equatable, Sendable {
    case natural
    case everyByte
}

public struct ScanProgress: Sendable {
    public let processed: Int
    public let total: Int
    public let matches: Int
}

public struct ScanResult: Identifiable, Equatable, Sendable {
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
        regionID: UUID,
        regionName: String,
        offset: Int,
        dataType: MemoryDataType,
        initialValue: MemoryValue?,
        previousValue: MemoryValue?,
        currentValue: MemoryValue?,
        observedAt: Date = Date()
    ) {
        self.id = "\(regionID.uuidString):\(offset):\(dataType.rawValue)"
        self.regionID = regionID
        self.regionName = regionName
        self.offset = offset
        self.dataType = dataType
        self.initialValue = initialValue
        self.previousValue = previousValue
        self.currentValue = currentValue
        self.observedAt = observedAt
    }
}

public actor MemoryScanner {
    private var candidates: [ScanResult] = []
    private var tolerance: Double
    private var maximumResults: Int
    private var didTruncateResults = false

    public init(tolerance: Double = 0, maximumResults: Int = 250_000) {
        self.tolerance = max(0, tolerance)
        self.maximumResults = max(1, maximumResults)
    }

    public func setTolerance(_ value: Double) {
        tolerance = max(0, value)
    }

    public func setMaximumResults(_ value: Int) throws {
        guard value > 0 else { throw MemoryEngineError.invalidValue("result limit") }
        maximumResults = value
    }

    public func results() -> [ScanResult] { candidates }
    public func resultsWereTruncated() -> Bool { didTruncateResults }

    public func clear() {
        candidates.removeAll(keepingCapacity: false)
        didTruncateResults = false
    }

    @discardableResult
    public func scanBytes(
        regions: [RegisteredRegionSnapshot],
        pattern: BytePattern,
        resultLimit: Int? = nil,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> [ScanResult] {
        guard !pattern.bytes.isEmpty else { throw MemoryEngineError.invalidPattern("") }
        let limit = resultLimit ?? maximumResults
        guard limit > 0 else { throw MemoryEngineError.invalidValue("result limit") }
        didTruncateResults = false
        let total = regions.reduce(0) { $0 + max(0, $1.bytes.count - pattern.bytes.count + 1) }
        var found: [ScanResult] = []
        var processed = 0
        for region in regions {
            guard region.bytes.count >= pattern.bytes.count else { continue }
            for offset in 0...(region.bytes.count - pattern.bytes.count) {
                if cancellation() { throw CancellationError() }
                if pattern.matches(region.bytes, at: offset) {
                    let matched = Array(region.bytes[offset..<(offset + pattern.bytes.count)])
                    guard found.count < limit else {
                        didTruncateResults = true
                        break
                    }
                    found.append(ScanResult(
                        regionID: region.info.id,
                        regionName: region.info.name,
                        offset: offset,
                        dataType: .bytes,
                        initialValue: .bytes(matched),
                        previousValue: nil,
                        currentValue: .bytes(matched)
                    ))
                }
                processed += 1
                progress(ScanProgress(processed: processed, total: total, matches: found.count))
            }
            if didTruncateResults { break }
        }
        candidates = found
        return found
    }

    @discardableResult
    public func scanStrings(
        regions: [RegisteredRegionSnapshot],
        target: String,
        encoding: MemoryDataType,
        byteOrder: ByteOrder = .littleEndian,
        byteLength: Int,
        mode: StringMatchMode = .exact,
        caseSensitive: Bool = true,
        resultLimit: Int? = nil,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> [ScanResult] {
        guard [.utf8, .utf16, .ascii].contains(encoding),
              byteLength > 0,
              byteLength <= 1_048_576 else {
            throw MemoryEngineError.invalidValue("string encoding or length")
        }
        let limit = resultLimit ?? maximumResults
        guard limit > 0 else { throw MemoryEngineError.invalidValue("result limit") }
        didTruncateResults = false
        let step = encoding == .utf16 ? 2 : 1
        let total = regions.reduce(0) {
            $0 + ($1.bytes.count < byteLength ? 0 : (($1.bytes.count - byteLength) / step + 1) * step)
        }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var found: [ScanResult] = []
        var processed = 0
        for region in regions where region.bytes.count >= byteLength {
            for offset in stride(from: 0, through: region.bytes.count - byteLength, by: step) {
                if cancellation() { throw CancellationError() }
                let bytes = region.bytes.subdata(in: offset..<(offset + byteLength))
                if let value = try? encoding.decode(bytes, byteOrder: byteOrder),
                   case .text(let decoded) = value,
                   stringMatches(decoded, target: target, mode: mode, options: options) {
                    guard found.count < limit else {
                        didTruncateResults = true
                        break
                    }
                    found.append(ScanResult(
                        regionID: region.info.id,
                        regionName: region.info.name,
                        offset: offset,
                        dataType: encoding,
                        initialValue: .text(decoded),
                        previousValue: nil,
                        currentValue: .text(decoded)
                    ))
                }
                processed += step
                progress(ScanProgress(processed: min(processed, total), total: total, matches: found.count))
            }
            if didTruncateResults { break }
        }
        candidates = found
        return found
    }

    @discardableResult
    public func firstScan(
        regions: [RegisteredRegionSnapshot],
        type: MemoryDataType,
        criterion: FirstScanCriterion,
        byteOrder: ByteOrder = .littleEndian,
        alignment: MemoryScanAlignment = .natural,
        resultLimit: Int? = nil,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> [ScanResult] {
        guard type.isNumeric, let width = type.width else {
            throw MemoryEngineError.invalidValue("non-numeric first scan")
        }
        let limit = resultLimit ?? maximumResults
        guard limit > 0 else { throw MemoryEngineError.invalidValue("result limit") }
        let expected = try expectedValue(for: criterion, type: type, byteOrder: byteOrder)
        let step = alignment == .natural ? width : 1
        let total = regions.reduce(0) {
            $0 + ($1.bytes.count < width ? 0 : (($1.bytes.count - width) / step + 1) * width)
        }
        var found: [ScanResult] = []
        var processed = 0
        didTruncateResults = false

        for region in regions {
            guard region.bytes.count >= width else { continue }
            for offset in stride(from: 0, through: region.bytes.count - width, by: step) {
                if cancellation() { throw CancellationError() }
                let slice = region.bytes.subdata(in: offset..<(offset + width))
                if let value = try? type.decode(slice, byteOrder: byteOrder),
                   matchesFirst(value, criterion: criterion, expected: expected) {
                    guard found.count < limit else {
                        didTruncateResults = true
                        break
                    }
                    found.append(ScanResult(
                        regionID: region.info.id,
                        regionName: region.info.name,
                        offset: offset,
                        dataType: type,
                        initialValue: value,
                        previousValue: nil,
                        currentValue: value
                    ))
                }
                processed += width
                progress(ScanProgress(processed: min(processed, total), total: total, matches: found.count))
            }
            if didTruncateResults { break }
        }
        candidates = found
        return found
    }

    @discardableResult
    public func nextScan(
        regions: [RegisteredRegionSnapshot],
        criterion: NextScanCriterion,
        byteOrder: ByteOrder = .littleEndian,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> [ScanResult] {
        didTruncateResults = false
        let regionLookup = Dictionary(uniqueKeysWithValues: regions.map { ($0.info.id, $0) })
        let previousCandidates = candidates
        var refined: [ScanResult] = []
        for (index, candidate) in previousCandidates.enumerated() {
            if cancellation() { throw CancellationError() }
            guard let region = regionLookup[candidate.regionID],
                  let width = candidate.dataType.width,
                  candidate.offset + width <= region.bytes.count else {
                progress(ScanProgress(processed: index + 1, total: previousCandidates.count, matches: refined.count))
                continue
            }
            let bytes = region.bytes.subdata(in: candidate.offset..<(candidate.offset + width))
            guard let current = try? candidate.dataType.decode(bytes, byteOrder: byteOrder),
                  matchesNext(current, candidate: candidate, criterion: criterion, type: candidate.dataType, byteOrder: byteOrder) else {
                progress(ScanProgress(processed: index + 1, total: previousCandidates.count, matches: refined.count))
                continue
            }
            var updated = candidate
            updated.previousValue = candidate.currentValue
            updated.currentValue = current
            updated.observedAt = Date()
            refined.append(updated)
            progress(ScanProgress(processed: index + 1, total: previousCandidates.count, matches: refined.count))
        }
        candidates = refined
        return refined
    }

    private func expectedValue(
        for criterion: FirstScanCriterion,
        type: MemoryDataType,
        byteOrder: ByteOrder
    ) throws -> (MemoryValue, MemoryValue?)? {
        switch criterion {
        case .unknown:
            return nil
        case .bytes:
            throw MemoryEngineError.invalidValue("byte pattern with numeric scan")
        case .exact(let value), .greaterThan(let value), .lessThan(let value):
            return (try decodeInput(value, type: type, byteOrder: byteOrder), nil)
        case .between(let lower, let upper):
            return (
                try decodeInput(lower, type: type, byteOrder: byteOrder),
                try decodeInput(upper, type: type, byteOrder: byteOrder)
            )
        }
    }

    private func matchesFirst(
        _ value: MemoryValue,
        criterion: FirstScanCriterion,
        expected: (MemoryValue, MemoryValue?)?
    ) -> Bool {
        guard let expected else { return true }
        switch criterion {
        case .exact:
            return value.compared(to: expected.0, tolerance: tolerance) == .orderedSame
        case .greaterThan:
            return value.compared(to: expected.0, tolerance: tolerance) == .orderedDescending
        case .lessThan:
            return value.compared(to: expected.0, tolerance: tolerance) == .orderedAscending
        case .between:
            guard let upper = expected.1,
                  let low = value.compared(to: expected.0, tolerance: tolerance),
                  let high = value.compared(to: upper, tolerance: tolerance) else { return false }
            return low != .orderedAscending && high != .orderedDescending
        case .unknown, .bytes:
            return true
        }
    }

    private func matchesNext(
        _ current: MemoryValue,
        candidate: ScanResult,
        criterion: NextScanCriterion,
        type: MemoryDataType,
        byteOrder: ByteOrder
    ) -> Bool {
        let previous = candidate.currentValue ?? candidate.initialValue
        guard let previous else { return false }
        switch criterion {
        case .exact(let input):
            guard let expected = try? decodeInput(input, type: type, byteOrder: byteOrder) else { return false }
            return current.compared(to: expected, tolerance: tolerance) == .orderedSame
        case .greaterThan(let input):
            guard let expected = try? decodeInput(input, type: type, byteOrder: byteOrder) else { return false }
            return current.compared(to: expected, tolerance: tolerance) == .orderedDescending
        case .lessThan(let input):
            guard let expected = try? decodeInput(input, type: type, byteOrder: byteOrder) else { return false }
            return current.compared(to: expected, tolerance: tolerance) == .orderedAscending
        case .between(let lower, let upper):
            guard let lowValue = try? decodeInput(lower, type: type, byteOrder: byteOrder),
                  let highValue = try? decodeInput(upper, type: type, byteOrder: byteOrder),
                  let low = current.compared(to: lowValue, tolerance: tolerance),
                  let high = current.compared(to: highValue, tolerance: tolerance) else { return false }
            return low != .orderedAscending && high != .orderedDescending
        case .increased:
            return current.compared(to: previous, tolerance: tolerance) == .orderedDescending
        case .decreased:
            return current.compared(to: previous, tolerance: tolerance) == .orderedAscending
        case .changed:
            guard let comparison = current.compared(to: previous, tolerance: tolerance) else { return false }
            return comparison != .orderedSame
        case .unchanged, .sameAsInitial:
            let comparison = criterion == .sameAsInitial ? candidate.initialValue : previous
            return comparison.map { current.compared(to: $0, tolerance: tolerance) == .orderedSame } ?? false
        case .increasedBy(let input):
            guard let amount = try? decodeInput(input, type: type, byteOrder: byteOrder),
                  let expected = adding(previous, amount) else { return false }
            return current.compared(to: expected, tolerance: tolerance) == .orderedSame
        case .decreasedBy(let input):
            guard let amount = try? decodeInput(input, type: type, byteOrder: byteOrder),
                  let expected = subtracting(previous, amount) else { return false }
            return current.compared(to: expected, tolerance: tolerance) == .orderedSame
        }
    }

    private func decodeInput(_ input: String, type: MemoryDataType, byteOrder: ByteOrder) throws -> MemoryValue {
        try type.decode(type.encode(input, byteOrder: byteOrder), byteOrder: byteOrder)
    }

    private func stringMatches(
        _ value: String,
        target: String,
        mode: StringMatchMode,
        options: String.CompareOptions
    ) -> Bool {
        switch mode {
        case .exact: value.compare(target, options: options) == .orderedSame
        case .prefix: value.range(of: target, options: options.union(.anchored))?.lowerBound == value.startIndex
        case .suffix: value.range(of: target, options: options.union(.anchored).union(.backwards))?.upperBound == value.endIndex
        case .substring: value.range(of: target, options: options) != nil
        }
    }

    private func adding(_ lhs: MemoryValue, _ rhs: MemoryValue) -> MemoryValue? {
        switch (lhs, rhs) {
        case (.signed(let a), .signed(let b)): let (v, overflow) = a.addingReportingOverflow(b); return overflow ? nil : .signed(v)
        case (.unsigned(let a), .unsigned(let b)): let (v, overflow) = a.addingReportingOverflow(b); return overflow ? nil : .unsigned(v)
        case (.floating(let a), .floating(let b)): return .floating(a + b)
        default: return nil
        }
    }

    private func subtracting(_ lhs: MemoryValue, _ rhs: MemoryValue) -> MemoryValue? {
        switch (lhs, rhs) {
        case (.signed(let a), .signed(let b)): let (v, overflow) = a.subtractingReportingOverflow(b); return overflow ? nil : .signed(v)
        case (.unsigned(let a), .unsigned(let b)): let (v, overflow) = a.subtractingReportingOverflow(b); return overflow ? nil : .unsigned(v)
        case (.floating(let a), .floating(let b)): return .floating(a - b)
        default: return nil
        }
    }
}
