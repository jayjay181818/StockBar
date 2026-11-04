import XCTest
@testable import Stockbar

@MainActor
final class RefreshSchedulerTests: XCTestCase {
    @MainActor
    private final class PassRecorder {
        var passes: [RefreshRequest] = []
        var gate: CheckedContinuation<Void, Never>?
        var gateFirstPass = true

        func run(_ request: RefreshRequest) async {
            passes.append(request)
            if passes.count == 1, gateFirstPass {
                await withCheckedContinuation { gate = $0 }
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
    }

    func testRequestsMadeDuringARunningPassAreQueuedForOneFollowUp() async {
        // Given: A pass that is still running.
        let recorder = PassRecorder()
        let scheduler = RefreshPassScheduler { await recorder.run($0) }
        let first = Task { await scheduler.schedule(RefreshRequest(symbols: nil, force: false)) }
        await waitUntil { recorder.gate != nil }
        XCTAssertTrue(scheduler.isRunning)

        // When: Targeted, forced requests arrive mid-pass (e.g. manual retry).
        await scheduler.schedule(RefreshRequest(symbols: ["AAPL"], force: true))
        await scheduler.schedule(RefreshRequest(symbols: ["MSFT"], force: true))
        XCTAssertEqual(recorder.passes.count, 1, "Queued requests must not run concurrently")

        recorder.gate?.resume()
        await first.value

        // Then: They were not dropped; one follow-up pass covers both symbols, still forced.
        XCTAssertEqual(recorder.passes.count, 2)
        XCTAssertEqual(recorder.passes[1], RefreshRequest(symbols: ["AAPL", "MSFT"], force: true))
        XCTAssertFalse(scheduler.isRunning)
    }

    func testIdleSchedulerRunsEachRequestImmediately() async {
        let recorder = PassRecorder()
        recorder.gateFirstPass = false
        let scheduler = RefreshPassScheduler { await recorder.run($0) }

        await scheduler.schedule(RefreshRequest(symbols: ["AAPL"], force: false))
        await scheduler.schedule(RefreshRequest(symbols: nil, force: true))

        XCTAssertEqual(recorder.passes, [
            RefreshRequest(symbols: ["AAPL"], force: false),
            RefreshRequest(symbols: nil, force: true)
        ])
    }

    func testQueueMergesMatchingForceAndServesForcedRequestsFirst() {
        var queue = RefreshRequestQueue()
        queue.enqueue(RefreshRequest(symbols: ["AAPL"], force: false))
        queue.enqueue(RefreshRequest(symbols: ["MSFT"], force: false))
        queue.enqueue(RefreshRequest(symbols: ["TSLA"], force: true))

        XCTAssertEqual(queue.dequeue(), RefreshRequest(symbols: ["TSLA"], force: true))
        XCTAssertEqual(queue.dequeue(), RefreshRequest(symbols: ["AAPL", "MSFT"], force: false))
        XCTAssertNil(queue.dequeue())
        XCTAssertTrue(queue.isEmpty)
    }

    func testWholePortfolioRequestAbsorbsTargetedOnesOfTheSameKind() {
        var queue = RefreshRequestQueue()
        queue.enqueue(RefreshRequest(symbols: ["AAPL"], force: false))
        queue.enqueue(RefreshRequest(symbols: nil, force: false))
        queue.enqueue(RefreshRequest(symbols: ["MSFT"], force: false))

        XCTAssertEqual(queue.dequeue(), RefreshRequest(symbols: nil, force: false))
        XCTAssertNil(queue.dequeue())
    }
}
