import Testing
@testable import HubCore

@Suite struct ForegroundActivationTests {
    @Test func confirmsOnlyAfterContinuousDwellInTheCorrectInstance() {
        var attempt = ForegroundActivationAttempt(targetPID: 20, startedAt: 0)
        #expect(attempt.observe(frontmostPID: 10, at: 0) == .waiting)
        #expect(attempt.observe(frontmostPID: 20, at: 1) == .waiting)
        #expect(attempt.observe(frontmostPID: 20, at: 3.9) == .waiting)
        #expect(attempt.observe(frontmostPID: 20, at: 4) == .confirmed)
    }

    @Test func losingFocusAfterActivationIsAnInterruption() {
        var attempt = ForegroundActivationAttempt(targetPID: 20, startedAt: 0)
        #expect(attempt.observe(frontmostPID: 20, at: 0) == .waiting)
        #expect(attempt.observe(frontmostPID: 10, at: 1) == .interrupted)
        // 切回来也不能把被打断的三秒计为成功。
        #expect(attempt.observe(frontmostPID: 20, at: 3) == .interrupted)
    }

    @Test func anotherBotCannotCountAsTheTarget() {
        var attempt = ForegroundActivationAttempt(targetPID: 20, startedAt: 0)
        #expect(attempt.observe(frontmostPID: 21, at: 3) == .waiting)
        #expect(attempt.observe(frontmostPID: 21, at: 6) == .timedOut)
    }

    @Test func delayedActivationStillNeedsAFullDwell() {
        var attempt = ForegroundActivationAttempt(targetPID: 20, startedAt: 0)
        #expect(attempt.observe(frontmostPID: nil, at: 5) == .waiting)
        #expect(attempt.observe(frontmostPID: 20, at: 5.5) == .waiting)
        #expect(attempt.observe(frontmostPID: 20, at: 6) == .waiting)
        #expect(attempt.observe(frontmostPID: 20, at: 8.5) == .confirmed)
    }

    @Test func activationAfterTimeoutCannotReviveTheOldAttempt() {
        var attempt = ForegroundActivationAttempt(targetPID: 20, startedAt: 0)
        #expect(attempt.observe(frontmostPID: nil, at: 6) == .timedOut)
        #expect(attempt.observe(frontmostPID: 20, at: 9) == .timedOut)
    }

    @Test func firstArrivalAfterDeadlineStillTimesOut() {
        var attempt = ForegroundActivationAttempt(targetPID: 20, startedAt: 0)
        #expect(attempt.observe(frontmostPID: 10, at: 5) == .waiting)
        #expect(attempt.observe(frontmostPID: 20, at: 7) == .timedOut)
    }
}
