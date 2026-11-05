import Combine
import Observation

/// Bridges `@Observable` models to Combine for AppKit and service code that
/// cannot use SwiftUI's automatic observation tracking.
///
/// `values(of:)` stands in for an `@Published` property's `$property` publisher:
/// it emits the current value on subscription, then the new value after any
/// observed property read by `read` changes. Two differences are deliberate:
/// - values are delivered after the change has been applied (on the next
///   main-actor turn), so subscribers always read consistent model state;
/// - several changes in one main-actor turn coalesce into a single value.
///
/// The subscription owns the tracking; cancelling it stops observation.
@MainActor
enum ObservationPublisher {
    static func values<Value>(of read: @escaping @MainActor () -> Value) -> AnyPublisher<Value, Never> {
        let relay = ObservationRelay(read: read)
        // Capturing the relay ties its lifetime to the subscription.
        return relay.subject
            .handleEvents(receiveCancel: { relay.stop() })
            .eraseToAnyPublisher()
    }

    /// `values(of:)` for one property. The model is held weakly, so a
    /// subscription stored on the model itself does not keep it alive; after
    /// the model is gone the last value is repeated.
    static func values<Root: AnyObject, Value>(
        _ root: Root,
        _ keyPath: KeyPath<Root, Value>
    ) -> AnyPublisher<Value, Never> {
        var lastValue = root[keyPath: keyPath]
        return values { [weak root] in
            if let root {
                lastValue = root[keyPath: keyPath]
            }
            return lastValue
        }
    }

    /// Emits only after a change to anything `read` touches; no initial value.
    static func changes(of read: @escaping @MainActor () -> Void) -> AnyPublisher<Void, Never> {
        values(of: read).dropFirst().eraseToAnyPublisher()
    }
}

@MainActor
private final class ObservationRelay<Value> {
    private let read: @MainActor () -> Value
    private var isStopped = false
    private(set) var subject: CurrentValueSubject<Value, Never>!

    init(read: @escaping @MainActor () -> Value) {
        self.read = read
        subject = CurrentValueSubject(trackedRead())
    }

    func stop() {
        isStopped = true
    }

    /// Reads the value and registers for the next change in the same pass, so
    /// no change can slip between reading and re-arming.
    private func trackedRead() -> Value {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            // Called synchronously before the mutation is stored, possibly off
            // the main thread; publish the stored value on the main actor.
            Task { @MainActor [weak self] in
                self?.publishChange()
            }
        }
    }

    private func publishChange() {
        guard !isStopped else { return }
        subject.send(trackedRead())
    }
}
