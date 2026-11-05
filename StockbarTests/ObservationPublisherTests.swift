import Combine
import Observation
import XCTest
@testable import Stockbar

@MainActor
final class ObservationPublisherTests: XCTestCase {

    @Observable
    final class Model {
        var count = 0
        var label = "a"
    }

    func testValuesEmitsCurrentValueThenChanges() async {
        let model = Model()
        var received: [Int] = []
        let changed = expectation(description: "change delivered")
        let subscription = ObservationPublisher.values(model, \.count).sink { value in
            received.append(value)
            if received.count == 2 { changed.fulfill() }
        }

        XCTAssertEqual(received, [0], "The current value is delivered on subscription, like @Published")
        model.count = 5

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(received, [0, 5])
        subscription.cancel()
    }

    func testChangesInOneTurnCoalesceToTheFinalValue() async {
        let model = Model()
        var received: [Int] = []
        let subscription = ObservationPublisher.values(model, \.count).sink { received.append($0) }

        model.count = 1
        model.count = 2
        model.count = 3
        await drainMainActor()

        XCTAssertEqual(received, [0, 3])
        subscription.cancel()
    }

    func testAssigningAnEqualValueDoesNotEmit() async {
        let model = Model()
        var received: [String] = []
        let subscription = ObservationPublisher.values(model, \.label).sink { received.append($0) }

        model.label = "a"
        await drainMainActor()

        XCTAssertEqual(received, ["a"])
        subscription.cancel()
    }

    func testChangesSkipsInitialValueAndTracksEveryPropertyRead() async {
        let model = Model()
        var changeCount = 0
        let subscription = ObservationPublisher.changes {
            _ = model.count
            _ = model.label
        }
        .sink { changeCount += 1 }

        XCTAssertEqual(changeCount, 0)
        model.label = "b"
        await drainMainActor()
        XCTAssertEqual(changeCount, 1)

        model.count = 7
        await drainMainActor()
        XCTAssertEqual(changeCount, 2, "Tracking must be re-armed after each change")
        subscription.cancel()
    }

    func testCancelledSubscriptionStopsDelivery() async {
        let model = Model()
        var received: [Int] = []
        let subscription = ObservationPublisher.values(model, \.count).sink { received.append($0) }

        model.count = 1
        subscription.cancel()
        await drainMainActor()

        XCTAssertEqual(received, [0])
    }

    func testKeyPathPublisherDoesNotRetainModel() {
        var model: Model? = Model()
        weak let weakModel = model
        let subscription = ObservationPublisher.values(model!, \.count).sink { _ in }

        model = nil

        XCTAssertNil(weakModel, "A subscription stored on the model must not keep it alive")
        subscription.cancel()
    }

    /// Change delivery is enqueued on the main actor during the mutation, so a
    /// main-actor task enqueued afterwards runs after it.
    private func drainMainActor() async {
        await Task { @MainActor in }.value
    }
}
