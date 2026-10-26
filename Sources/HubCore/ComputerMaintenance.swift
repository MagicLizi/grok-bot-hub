import Foundation

/// 电脑画面报告的状态，与桌面程序本身的健康状态分开。
public enum ComputerState: String, Sendable {
    case awake, onDevice, asleep, waking, unreachable, away, paused, notShown, unrecognizedFullscreen

    public var isAvailable: Bool { self == .awake || self == .onDevice }
}

/// 每台电脑独立计时；一台恢复失败不会拖延其他电脑的巡检或前台轮换。
public struct ComputerMaintenanceSchedule {
    public static let checkInterval: TimeInterval = 30
    public static let activationInterval: TimeInterval = 180
    public private(set) var nextCheckAt = Date.distantPast
    public private(set) var nextActivationAt = Date.distantPast
    public private(set) var nextRecoveryAt = Date.distantPast
    public private(set) var failures = 0

    public init() {}

    public func isDue(at now: Date) -> Bool { now >= nextCheckAt }

    public func needsRecovery(for state: ComputerState, at now: Date) -> Bool {
        guard now >= nextRecoveryAt, state != .onDevice, state != .paused else { return false }
        return state != .awake || now >= nextActivationAt
    }

    public mutating func inspected(at now: Date) {
        nextCheckAt = now.addingTimeInterval(Self.checkInterval)
    }

    public mutating func activated(at now: Date) {
        nextActivationAt = now.addingTimeInterval(Self.activationInterval)
    }

    public mutating func completed(success: Bool, at now: Date) {
        if success {
            failures = 0
            nextRecoveryAt = .distantPast
        } else {
            let delays: [TimeInterval] = [30, 60, 120, 300]
            nextRecoveryAt = now.addingTimeInterval(delays[min(failures, delays.count - 1)])
            failures += 1
        }
        inspected(at: now)
    }
}
