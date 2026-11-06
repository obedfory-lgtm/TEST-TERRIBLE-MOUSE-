import Foundation

public struct ValueObservation: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let regionID: UUID
    public let regionName: String
    public let changedByteCount: Int
    public let kind: ObservationKind
}

public enum ObservationKind: String, Codable, Equatable, Sendable {
    case newSample
    case changed
    case unchanged
    case disappeared
}

public actor LiveValueMonitor {
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<ValueObservation>.Continuation?
    private var previous: [UUID: Data] = [:]
    private var history: [ValueObservation] = []
    private var isPaused = false
    private let maximumHistory: Int

    public init(maximumHistory: Int = 2_000) { self.maximumHistory = max(1, maximumHistory) }

    public func start(registry: MemoryRegionRegistry, interval: TimeInterval = 1) throws -> AsyncStream<ValueObservation> {
        guard task == nil else { throw MemoryEngineError.invalidValue("monitor already running") }
        let channel = AsyncStream<ValueObservation>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation = channel.continuation
        let sampleInterval = min(60, max(0.5, interval))
        task = Task { await sampleLoop(registry: registry, interval: sampleInterval) }
        return channel.stream
    }

    public func pause() { isPaused = true }
    public func resume() { isPaused = false }
    public func observations() -> [ValueObservation] { history }

    public func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
        previous.removeAll(keepingCapacity: false)
    }

    private func sampleLoop(registry: MemoryRegionRegistry, interval: TimeInterval) async {
        while !Task.isCancelled {
            if !isPaused {
                let current = await registry.snapshots()
                let currentIDs = Set(current.map { $0.info.id })
                for region in current {
                    let old = previous[region.info.id]
                    let changedCount: Int
                    let kind: ObservationKind
                    if let old {
                        changedCount = Self.changedBytes(old, region.bytes)
                        kind = changedCount == 0 ? .unchanged : .changed
                    } else {
                        changedCount = region.bytes.count
                        kind = .newSample
                    }
                    publish(ValueObservation(id: UUID(), timestamp: Date(), regionID: region.info.id, regionName: region.info.name, changedByteCount: changedCount, kind: kind))
                    previous[region.info.id] = region.bytes
                }
                for id in Set(previous.keys).subtracting(currentIDs) {
                    publish(ValueObservation(id: UUID(), timestamp: Date(), regionID: id, regionName: id.uuidString, changedByteCount: 0, kind: .disappeared))
                    previous[id] = nil
                }
            }
            do { try await Task.sleep(for: .seconds(interval)) } catch { break }
        }
    }

    private func publish(_ value: ValueObservation) {
        history.append(value)
        if history.count > maximumHistory { history.removeFirst(history.count - maximumHistory) }
        continuation?.yield(value)
    }

    private static func changedBytes(_ lhs: Data, _ rhs: Data) -> Int {
        let shared = min(lhs.count, rhs.count)
        return zip(lhs.prefix(shared), rhs.prefix(shared)).reduce(lhs.count == rhs.count ? 0 : abs(lhs.count - rhs.count)) {
            $0 + ($1.0 == $1.1 ? 0 : 1)
        }
    }
}