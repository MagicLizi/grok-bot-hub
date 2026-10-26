import Foundation

/// 保活重启的退避策略：连续重启越多等得越久，稳定运行一段时间后清零。
public struct RestartPolicy {
    public var delays: [TimeInterval]
    /// 连续运行超过这个时长视为恢复稳定，退避计数清零。
    public var stableAfter: TimeInterval

    public init(delays: [TimeInterval] = [2, 5, 10, 30, 60, 120, 300], stableAfter: TimeInterval = 600) {
        precondition(!delays.isEmpty)
        self.delays = delays
        self.stableAfter = stableAfter
    }

    /// `consecutiveRestarts` 为已经发生的连续自动重启次数（第一次重启传 0）。
    public func delay(forConsecutiveRestarts n: Int) -> TimeInterval {
        delays[min(max(n, 0), delays.count - 1)]
    }

    public func isStable(runningSince: Date, now: Date) -> Bool {
        now.timeIntervalSince(runningSince) >= stableAfter
    }
}

/// 无响应判定：连续多次健康检查失败才算卡死，启动初期给足宽限。
public struct HangPolicy {
    public var failuresBeforeRestart: Int
    public var startupGrace: TimeInterval

    public init(failuresBeforeRestart: Int = 4, startupGrace: TimeInterval = 90) {
        self.failuresBeforeRestart = failuresBeforeRestart
        self.startupGrace = startupGrace
    }

    public func shouldRestart(consecutiveFailures: Int, runningSince: Date?, now: Date) -> Bool {
        guard consecutiveFailures >= failuresBeforeRestart else { return false }
        guard let since = runningSince else { return true }
        return now.timeIntervalSince(since) >= startupGrace
    }
}
