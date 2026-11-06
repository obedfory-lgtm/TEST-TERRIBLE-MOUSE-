import Foundation

public enum ObservationKind: String, Equatable, Sendable {
    case newSample
    case changed
    case unchanged
    case disappeared
}

public struct LiveValueObservation: Sendable {
    public let regionID: UUID
    public let regionName: String
    public let kind: ObservationKind
    public let previousByteCount: Int?
    public let currentByteCount: Int?
    public let observedAt: Date
}

public actor LiveValueMonitor {
    private var pollingTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<LiveValueObservation, Error>.Continuation?
    private var isPaused = false
    private var previousRegions: [UUID: RegisteredRegionSnapshot] = [:]
    private var observations: [LiveValueObservation] = []
    private let maximumHistory: Int

    public init(maximumHistory: Int = 10_000) {
        self.maximumHistory = max(1, maximumHistory)
    }

    public func start(
        registry: MemoryRegionRegistry,
        interval: TimeInterval = 1
    ) throws -> AsyncThrowingStream<LiveValueObservation, Error> {
        guard pollingTask == nil else { throw MemoryEngineError.monitorAlreadyRunning }
        let pair = AsyncThrowingStream<LiveValueObservation, Error>.makeStream()
        continuation = pair.continuation
        isPaused = false
        let sampleInterval = min(60, max(0.1, interval))
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.sample(registry: registry)
                } catch {
                    await self.finish(throwing: error)
                    return
                }
                try? await Task.sleep(for: .seconds(sampleInterval))
            }
            await self?.finish()
        }
        return pair.stream
    }

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        continuation?.finish()
        continuation = nil
        isPaused = false
        previousRegions.removeAll(keepingCapacity: false)
    }

    public func history() -> [LiveValueObservation] {
        observations
    }

    private func sample(registry: MemoryRegionRegistry) async throws {
        guard !isPaused, let continuation else { return }
        let currentRegions = try await registry.snapshots()
        let currentByID = Dictionary(uniqueKeysWithValues: currentRegions.map { ($0.info.id, $0) })
        let now = Date()

        for region in currentRegions {
            let kind: ObservationKind
            if let previous = previousRegions[region.info.id] {
                kind = previous.bytes == region.bytes ? .unchanged : .changed
            } else {
                kind = .newSample
            }
            publish(
                LiveValueObservation(
                    regionID: region.info.id,
                    regionName: region.info.name,
                    kind: kind,
                    previousByteCount: previousRegions[region.info.id]?.bytes.count,
                    currentByteCount: region.bytes.count,
                    observedAt: now
                ),
                to: continuation
            )
        }

        for (id, previous) in previousRegions where currentByID[id] == nil {
            publish(
                LiveValueObservation(
                    regionID: id,
                    regionName: previous.info.name,
                    kind: .disappeared,
                    previousByteCount: previous.bytes.count,
                    currentByteCount: nil,
                    observedAt: now
                ),
                to: continuation
            )
        }
        previousRegions = currentByID
    }

    private func publish(
        _ observation: LiveValueObservation,
        to continuation: AsyncThrowingStream<LiveValueObservation, Error>.Continuation
    ) {
        observations.append(observation)
        if observations.count > maximumHistory {
            observations.removeFirst(observations.count - maximumHistory)
        }
        continuation.yield(observation)
    }

    private func finish(throwing error: Error? = nil) {
        pollingTask = nil
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
        previousRegions.removeAll(keepingCapacity: false)
    }
}
