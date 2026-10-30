import Foundation

/// 周期巡检不依赖界面线程的 RunLoop Timer；一轮结束后再等待，避免积压巡检任务。
public enum MonitoringLoop {
    public static func start(
        every interval: Duration,
        action: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await action()
            }
        }
    }
}
