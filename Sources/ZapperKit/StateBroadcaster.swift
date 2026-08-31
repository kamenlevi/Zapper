import Foundation

/// Multicasts a current-value state to any number of async consumers, and
/// replays the latest value to each new one so a view that subscribes late
/// still renders correctly.
public final class StateBroadcaster<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: T
    private var continuations: [UUID: AsyncStream<T>.Continuation] = [:]

    public init(_ initial: T) { self.current = initial }

    public var value: T {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func send(_ newValue: T) {
        lock.lock()
        current = newValue
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(newValue) }
    }

    public func mutate(_ transform: (inout T) -> Void) {
        lock.lock()
        transform(&current)
        let snapshot = current
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(snapshot) }
    }

    public func stream() -> AsyncStream<T> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let snapshot = current
            lock.unlock()

            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }
}
