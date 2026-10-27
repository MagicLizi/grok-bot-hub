import Foundation
import Testing
@testable import HubCore

@Suite struct ComputerMaintenanceTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func checksEveryThirtySecondsAndRotatesEveryThreeMinutes() {
        var schedule = ComputerMaintenanceSchedule()
        #expect(schedule.isDue(at: now))
        #expect(schedule.needsRecovery(for: .awake, at: now))
        schedule.inspected(at: now)
        schedule.activated(at: now)
        #expect(!schedule.isDue(at: now.addingTimeInterval(29)))
        #expect(schedule.isDue(at: now.addingTimeInterval(30)))
        #expect(!schedule.needsRecovery(for: .awake, at: now.addingTimeInterval(179)))
        #expect(schedule.needsRecovery(for: .awake, at: now.addingTimeInterval(180)))
    }

    @Test func recoversSleepAndConnectionFailuresBeforeNextRotation() {
        var schedule = ComputerMaintenanceSchedule()
        schedule.activated(at: now)
        for state: ComputerState in [.asleep, .waking, .unreachable, .away, .notShown, .unrecognizedFullscreen] {
            #expect(schedule.needsRecovery(for: state, at: now.addingTimeInterval(1)))
        }
        #expect(!schedule.needsRecovery(for: .onDevice, at: now.addingTimeInterval(600)))
        #expect(!schedule.needsRecovery(for: .paused, at: now.addingTimeInterval(600)))
    }

    @Test func backsOffFailuresButKeepsInspectingAndResetsAfterRecovery() {
        var schedule = ComputerMaintenanceSchedule()
        var time = now
        for delay: TimeInterval in [30, 60, 120, 300, 300] {
            schedule.completed(success: false, at: time)
            #expect(schedule.nextRecoveryAt == time.addingTimeInterval(delay))
            #expect(!schedule.needsRecovery(for: .asleep, at: time.addingTimeInterval(delay - 1)))
            #expect(schedule.needsRecovery(for: .asleep, at: time.addingTimeInterval(delay)))
            #expect(schedule.isDue(at: time.addingTimeInterval(30)))
            time = time.addingTimeInterval(delay)
        }
        schedule.completed(success: true, at: time)
        #expect(schedule.failures == 0)
        schedule.completed(success: false, at: time)
        #expect(schedule.nextRecoveryAt == time.addingTimeInterval(30))
    }

    @Test func oneComputerCannotDelayAnother() {
        var failed = ComputerMaintenanceSchedule()
        var healthy = ComputerMaintenanceSchedule()
        failed.completed(success: false, at: now)
        healthy.activated(at: now)
        #expect(!failed.needsRecovery(for: .asleep, at: now.addingTimeInterval(1)))
        #expect(healthy.needsRecovery(for: .asleep, at: now.addingTimeInterval(1)))
        #expect(healthy.isDue(at: now))
    }

    @Test func interruptedRotationRetriesWithoutCountingAnotherFailure() {
        var schedule = ComputerMaintenanceSchedule()
        schedule.completed(success: false, at: now)
        let retry = now.addingTimeInterval(30)
        schedule.deferActivation(at: retry)
        #expect(schedule.failures == 1)
        #expect(!schedule.isDue(at: retry.addingTimeInterval(29)))
        #expect(schedule.isDue(at: retry.addingTimeInterval(30)))
        #expect(schedule.needsRecovery(for: .awake, at: retry.addingTimeInterval(30)))
        #expect(schedule.nextActivationAt == .distantPast)
    }
}
