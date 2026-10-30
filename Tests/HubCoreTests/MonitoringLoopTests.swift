import Foundation
import Testing
@testable import HubCore

@Suite struct MonitoringLoopTests {
    @Test func keepsPollingWithoutPumpingTheRunLoop() {
        let fired = DispatchSemaphore(value: 0)
        let task = MonitoringLoop.start(every: .milliseconds(10)) {
            fired.signal()
        }
        defer { task.cancel() }

        // 阻塞当前线程且不运行 RunLoop：原来的 scheduledTimer 无法在这里持续触发。
        for _ in 0..<3 {
            #expect(fired.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test func cancellationStopsFutureChecks() async throws {
        let counter = Counter()
        let task = MonitoringLoop.start(every: .milliseconds(10)) {
            await counter.increment()
        }
        defer { task.cancel() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await counter.value == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await counter.value > 0)
        task.cancel()
        await task.value
        let stoppedAt = await counter.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.value == stoppedAt)
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
}
