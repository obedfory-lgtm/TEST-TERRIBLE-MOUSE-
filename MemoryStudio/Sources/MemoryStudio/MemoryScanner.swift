import Foundation

public enum FirstScanCriterion: Equatable, Sendable {
    case exact(String)
    case greaterThan(String)
    case lessThan(String)
    case between(String, String)
    case unknown
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

public enum MemoryScanAlignment: Equatable, Sendable {
    case natural
    case everyByte
}

public enum StringMatchMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case exact
    case prefix
    case suffix
    case substring

    public var id: String { rawValue }
}

public actor MemoryScanner {
    private var candidates: [ScanResult] = []
    private var maximumResults: Int
    private var tolerance: Double
    private var truncated = false

    public init(maximumResults: Int = 100_000, tolerance: Double = 0) {
        self.maximumResults = max(1, maximumResults)
        self.tolerance = max(0, tolerance)
    }

    public func results() -> [ScanResult] { candidates }
    public func didTruncate() -> Bool { truncated }
    public func setTolerance(_ value: Double) { tolerance = max(0, value) }

    public func restoreCandidates(_ restored: [ScanResult]) {
        candidates = Array(restored.prefix(maximumResults))
        truncated = restored.count > maximumResults
    }

    public func clear() {
        candidates.removeAll(keepingCapacity: false)
        truncated = false
    }

    @discardableResult
    public func firstScan(
        regions: [RegisteredRegionSnapshot],
        type: MemoryDataType,
        criterion: FirstScanCriterion,
        byteOrder: ByteOrder = .littleEndian,
        alignment: MemoryScanAlignment = .natural,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> [ScanResult] {
        guard let width = type.width else { throw MemoryEngineError.invalidValue("numeric data type") }
        let expected = try expectedValues(criterion, type: type, byteOrder: byteOrder)
        let step = alignment == .natural ? width : 1
        let total = regions.reduce(0) { count, region in
            count + (region.bytes.count < width ? 0 : (region.bytes.count - width) / step + 1)
        }
        var found: [ScanResult] = []
        truncated = false
        var processed = 0

        scanLoop: for region in regions where region.bytes.count >= width {
            for offset in stride(from: 0, through: region.bytes.count - width, by: step) {
                try checkCancellation(cancellation)
                let value = try type.decode(region.bytes, range: offset..<(offset + width), byteOrder: byteOrder)
                if matches(value, criterion: criterion, expected: expected) {
                    guard found.count < maximumResults else { truncated = true; break scanLoop }
                    found.append(ScanResult(
                        regionID: region.info.id,
                        regionName: region.info.name,
                        offset: offset,
                        dataType: type,
                        value: value
                    ))
                }
                processed += 1
                if processed.isMultiple(of: 4_096) || processed == total {
                    progress(ScanProgress(processed: processed, total: total, matches: found.count))
                }
            }
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
        let regionByID = Dictionary(uniqueKeysWithValues: regions.map { ($0.info.id, $0) })
        let previousCandidates = candidates
        var refined: [ScanResult] = []
        truncated = false

        for (index, candidate) in previousCandidates.enumerated() {
            try checkCancellation(cancellation)
            guard let region = regionByID[candidate.regionID],
                  let width = candidate.dataType.width,
                  candidate.offset >= 0,
                  candidate.offset <= region.bytes.count - width else {
                reportRefinementProgress(index: index, total: previousCandidates.count, matches: refined.count, progress: progress)
                continue
            }
            let current = try candidate.dataType.decode(
                region.bytes,
                range: candidate.offset..<(candidate.offset + width),
                byteOrder: byteOrder
            )
            guard matches(current, previous: candidate, criterion: criterion, type: candidate.dataType, byteOrder: byteOrder) else {
                reportRefinementProgress(index: index, total: previousCandidates.count, matches: refined.count, progress: progress)
                continue
            }
            var updated = candidate
            updated.previousValue = candidate.currentValue
            updated.currentValue = current
            updated.observedAt = Date()
            refined.append(updated)
            reportRefinementProgress(index: index, total: previousCandidates.count, matches: refined.count, progress: progress)
        }
        candidates = refined
        return refined
    }

    @discardableResult
    public func scanBytes(
        regions: [RegisteredRegionSnapshot],
        pattern: BytePattern,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> [ScanResult] {
        guard !pattern.bytes.isEmpty else { throw MemoryEngineError.invalidPattern("") }
        var found: [ScanResult] = []
        let total = regions.reduce(0) { $0 + max(0, $1.bytes.count - pattern.bytes.count + 1) }
        var processed = 0
        truncated = false
        scanLoop: for region in regions where region.bytes.count >= pattern.bytes.count {
            for offset in 0...(region.bytes.count - pattern.bytes.count) {
                try checkCancellation(cancellation)
                if pattern.matches(region.bytes, at: offset) {
                    guard found.count < maximumResults else { truncated = true; break scanLoop }
                    let match = Array(region.bytes[offset..<(offset + pattern.bytes.count)])
                    found.append(ScanResult(regionID: region.info.id, regionName: region.info.name, offset: offset, dataType: .bytes, value: .bytes(match)))
                }
                processed += 1
                if processed.isMultiple(of: 4_096) || processed == total {
                    progress(ScanProgress(processed: processed, total: total, matches: found.count))
                }
            }
        }
        candidates = found
        return found
    }

    @discardableResult
    public func scanStrings(
        regions: [RegisteredRegionSnapshot],
        target: String,
        encoding: MemoryDataType,
        byteLength: Int,
        byteOrder: ByteOrder = .littleEndian,
        mode: StringMatchMode = .exact,
        caseSensitive: Bool = true,
        cancellation: @Sendable () -> Bool = { false }
    ) throws -> [ScanResult] {
          guard [.utf8, .utf16, .ascii].contains(encoding), (1...65_536).contains(byteLength),
              encoding != .utf16 || byteLength.isMultiple(of: 2) else {
            throw MemoryEngineError.invalidValue("text encoding or byte length")
        }
        let strideSize = encoding == .utf16 ? 2 : 1
        var found: [ScanResult] = []
        truncated = false
        scanLoop: for region in regions where region.bytes.count >= byteLength {
            for offset in stride(from: 0, through: region.bytes.count - byteLength, by: strideSize) {
                try checkCancellation(cancellation)
                let data = region.bytes.subdata(in: offset..<(offset + byteLength))
                    guard let decoded = try? encoding.decode(data, byteOrder: byteOrder),
                        case .text(let value) = decoded,
                        stringMatches(value, target: target, mode: mode, caseSensitive: caseSensitive) else { continue }
                guard found.count < maximumResults else { truncated = true; break scanLoop }
                found.append(ScanResult(regionID: region.info.id, regionName: region.info.name, offset: offset, dataType: encoding, value: .text(value)))
            }
        }
        candidates = found
        return found
    }

    private func expectedValues(
        _ criterion: FirstScanCriterion,
        type: MemoryDataType,
        byteOrder: ByteOrder
    ) throws -> (MemoryValue, MemoryValue?)? {
        func decode(_ source: String) throws -> MemoryValue {
            try type.decode(type.encode(source, byteOrder: byteOrder), byteOrder: byteOrder)
        }
        switch criterion {
        case .unknown: return nil
        case .exact(let value), .greaterThan(let value), .lessThan(let value): return (try decode(value), nil)
        case .between(let low, let high): return (try decode(low), try decode(high))
        }
    }

    private func matches(
        _ value: MemoryValue,
        criterion: FirstScanCriterion,
        expected: (MemoryValue, MemoryValue?)?
    ) -> Bool {
        guard let expected else { return true }
        switch criterion {
        case .unknown: true
        case .exact: value.compared(to: expected.0, tolerance: tolerance) == .orderedSame
        case .greaterThan: value.compared(to: expected.0, tolerance: tolerance) == .orderedDescending
        case .lessThan: value.compared(to: expected.0, tolerance: tolerance) == .orderedAscending
        case .between:
            guard let upper = expected.1,
                  let low = value.compared(to: expected.0, tolerance: tolerance),
                  let high = value.compared(to: upper, tolerance: tolerance) else { return false }
            return low != .orderedAscending && high != .orderedDescending
        }
    }

    private func matches(
        _ value: MemoryValue,
        previous candidate: ScanResult,
        criterion: NextScanCriterion,
        type: MemoryDataType,
        byteOrder: ByteOrder
    ) -> Bool {
        guard let old = candidate.currentValue ?? candidate.initialValue else { return false }
        func decode(_ source: String) -> MemoryValue? {
            guard let data = try? type.encode(source, byteOrder: byteOrder) else { return nil }
            return try? type.decode(data, byteOrder: byteOrder)
        }
        switch criterion {
        case .exact(let input): return decode(input).map { value.compared(to: $0, tolerance: tolerance) == .orderedSame } ?? false
        case .greaterThan(let input): return decode(input).map { value.compared(to: $0, tolerance: tolerance) == .orderedDescending } ?? false
        case .lessThan(let input): return decode(input).map { value.compared(to: $0, tolerance: tolerance) == .orderedAscending } ?? false
        case .between(let low, let high):
            guard let lowValue = decode(low), let highValue = decode(high),
                  let lower = value.compared(to: lowValue, tolerance: tolerance),
                  let upper = value.compared(to: highValue, tolerance: tolerance) else { return false }
            return lower != .orderedAscending && upper != .orderedDescending
        case .increased: return value.compared(to: old, tolerance: tolerance) == .orderedDescending
        case .decreased: return value.compared(to: old, tolerance: tolerance) == .orderedAscending
        case .changed: return value.compared(to: old, tolerance: tolerance).map { $0 != .orderedSame } ?? false
        case .unchanged: return value.compared(to: old, tolerance: tolerance) == .orderedSame
        case .sameAsInitial:
            return candidate.initialValue.map { value.compared(to: $0, tolerance: tolerance) == .orderedSame } ?? false
        case .increasedBy(let amount):
            guard let increase = decode(amount), let expected = add(old, increase) else { return false }
            return value.compared(to: expected, tolerance: tolerance) == .orderedSame
        case .decreasedBy(let amount):
            guard let decrease = decode(amount), let expected = subtract(old, decrease) else { return false }
            return value.compared(to: expected, tolerance: tolerance) == .orderedSame
        }
    }

    private func stringMatches(_ value: String, target: String, mode: StringMatchMode, caseSensitive: Bool) -> Bool {
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        switch mode {
        case .exact: value.compare(target, options: options) == .orderedSame
        case .prefix: value.range(of: target, options: options.union(.anchored))?.lowerBound == value.startIndex
        case .suffix: value.range(of: target, options: options.union(.anchored).union(.backwards))?.upperBound == value.endIndex
        case .substring: value.range(of: target, options: options) != nil
        }
    }

    private func add(_ lhs: MemoryValue, _ rhs: MemoryValue) -> MemoryValue? {
        switch (lhs, rhs) {
        case (.signed(let a), .signed(let b)):
            let (value, overflow) = a.addingReportingOverflow(b)
            return overflow ? nil : .signed(value)
        case (.unsigned(let a), .unsigned(let b)):
            let (value, overflow) = a.addingReportingOverflow(b)
            return overflow ? nil : .unsigned(value)
        case (.floating(let a), .floating(let b)):
            let value = a + b
            return value.isFinite ? .floating(value) : nil
        default: return nil
        }
    }

    private func subtract(_ lhs: MemoryValue, _ rhs: MemoryValue) -> MemoryValue? {
        switch (lhs, rhs) {
        case (.signed(let a), .signed(let b)):
            let (value, overflow) = a.subtractingReportingOverflow(b)
            return overflow ? nil : .signed(value)
        case (.unsigned(let a), .unsigned(let b)):
            let (value, overflow) = a.subtractingReportingOverflow(b)
            return overflow ? nil : .unsigned(value)
        case (.floating(let a), .floating(let b)):
            let value = a - b
            return value.isFinite ? .floating(value) : nil
        default: return nil
        }
    }

    private func checkCancellation(_ cancellation: @Sendable () -> Bool) throws {
        if Task.isCancelled || cancellation() { throw CancellationError() }
    }

    private func reportRefinementProgress(
        index: Int,
        total: Int,
        matches: Int,
        progress: @Sendable (ScanProgress) -> Void
    ) {
        let processed = index + 1
        if processed.isMultiple(of: 256) || processed == total {
            progress(ScanProgress(processed: processed, total: total, matches: matches))
        }
    }
}