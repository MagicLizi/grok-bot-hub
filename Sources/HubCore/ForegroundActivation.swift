import Foundation

/// 必须是指定进程连续停留在前台；已经切过去后失去焦点，属于轮换中断。
public struct ForegroundActivationAttempt {
    public enum Status: Equatable {
        case waiting, confirmed, timedOut, interrupted
    }

    private let targetPID: Int32
    private let startedAt: TimeInterval
    private let activationTimeout: TimeInterval
    private let requiredDwell: TimeInterval
    private var foregroundSince: TimeInterval?
    private var status: Status = .waiting

    public init(targetPID: Int32, startedAt: TimeInterval,
                activationTimeout: TimeInterval = 6, requiredDwell: TimeInterval = 3) {
        self.targetPID = targetPID
        self.startedAt = startedAt
        self.activationTimeout = activationTimeout
        self.requiredDwell = requiredDwell
    }

    /// at 使用单调时钟，避免系统校时改变前台停留时长。
    public mutating func observe(frontmostPID: Int32?, at now: TimeInterval) -> Status {
        guard status == .waiting else { return status }
        if foregroundSince == nil && now - startedAt >= activationTimeout {
            status = .timedOut
        } else if frontmostPID == targetPID {
            if foregroundSince == nil { foregroundSince = now }
            if let foregroundSince, now - foregroundSince >= requiredDwell { status = .confirmed }
        } else if foregroundSince != nil {
            status = .interrupted
        }
        return status
    }
}
