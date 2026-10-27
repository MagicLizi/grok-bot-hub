import AppKit
import HubCore
import Observation

/// 一个 Bot 的运行时：进程状态机 + 保活 + 健康检查 + 登录。
///
/// 由 HubController 每 2 秒调用一次 `reconcile` 和 `tick`；所有状态都在主线程上变更。
@Observable
@MainActor
final class BotController: Identifiable {
    enum Phase: Equatable {
        case stopped
        case launching(since: Date)
        case running
        case waitingRestart(at: Date)
        case stopping
    }

    enum Health: Equatable {
        case unknown
        case connecting
        case ok
        /// 进程还在，但主窗口被关掉了（后台运行）
        case windowClosed
        /// 进程不是带调试端口启动的（比如用户自己双击打开），无法检测
        case noDebugPort
        case unresponsive(failures: Int)
    }

    enum Auth: Equatable {
        case unknown, loggedOut, loggingIn, loggedIn
    }

    struct Event: Identifiable {
        enum Level { case info, warning, error }
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    enum LoginError: LocalizedError {
        case grokBotMissing, noDebugPort, notReady, noLink, cancelled, timedOut

        var errorDescription: String? {
            switch self {
            case .grokBotMissing: return "没有找到 Grok Bot.app"
            case .noDebugPort: return "这个实例不是由管家启动的，请先重启它"
            case .notReady: return "Grok Bot 窗口迟迟没有就绪"
            case .noLink: return "没拿到登录链接"
            case .cancelled: return "登录已取消"
            case .timedOut: return "登录超时（20 分钟）"
            }
        }
    }

    private(set) var profile: BotProfile
    nonisolated let id: String

    private(set) var phase: Phase = .stopped
    private(set) var app: NSRunningApplication?
    private(set) var runningSince: Date?
    private(set) var health: Health = .unknown
    private(set) var auth: Auth = .unknown
    private(set) var autoRestarts = 0
    private(set) var events: [Event] = []
    private(set) var loginActive = false
    /// 手动或自动恢复电脑进行中。
    private(set) var wakeActive = false
    private(set) var computerState: ComputerState?
    private(set) var computerCheckedAt: Date?
    private(set) var computerIssue: String?
    private(set) var computerForegroundNote: String?
    private(set) var computerRetryAt: Date?
    private(set) var lastComputerActivationAt: Date?
    private(set) var autoComputerRecoveries = 0

    @ObservationIgnored private var computerTask: Task<Void, Never>?
    @ObservationIgnored private var computerEpoch = UUID()
    @ObservationIgnored private var computerSchedule = ComputerMaintenanceSchedule()
    @ObservationIgnored private var wakeToken: UUID?
    @ObservationIgnored private var wakeAutomatic = false
    @ObservationIgnored private var wakePID: pid_t?
    @ObservationIgnored private var wakeNeededRecovery = false

    private weak var hub: HubController?
    private var client: DevToolsClient?
    private var consecutiveRestarts = 0
    private var healthFailures = 0
    private var lastHealthCheck = Date.distantPast
    private var lastAuthCheck = Date.distantPast
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var checkEpoch = UUID()
    private var manualLaunchRequested = false
    private var restartRequested = false
    private var terminateRequestedAt: Date?
    private var activateOnNextLaunch = false
    private var titleTaggedPID: pid_t?
    private var logoutNotified = false
    @ObservationIgnored private var logoutActive = false

    private let restartPolicy = RestartPolicy()
    private let hangPolicy = HangPolicy()
    private static let healthInterval: TimeInterval = 30
    private static let launchTimeout: TimeInterval = 45
    private static let terminateTimeout: TimeInterval = 15
    private static let loginTimeout: TimeInterval = 20 * 60
    private static let maxEvents = 200

    init(profile: BotProfile, hub: HubController) {
        self.profile = profile
        self.id = profile.id
        self.hub = hub
    }

    var pid: pid_t? { app?.processIdentifier }
    var isRunning: Bool { app != nil }
    var keepAlivePaused: Bool { hub?.keepAlivePaused ?? HubSettings.keepAlivePaused }
    private var keepsProcessAlive: Bool { profile.keepAlive && !keepAlivePaused }
    var keepsComputerAwake: Bool { (hub?.keepingComputersAwake ?? HubSettings.keepComputersAwake) && keepsProcessAlive }
    var computerConfirmedAwake: Bool {
        isRunning && phase == .running && health == .ok && !loginActive && !logoutActive
            && terminateRequestedAt == nil && !restartRequested
            && auth == .loggedIn && computerState?.isAvailable == true && computerIssue == nil
            && computerCheckedAt.map { Date().timeIntervalSince($0) <= 90 } == true
            && !isMacScreenLocked()
    }

    // MARK: - 用户操作

    func start(activate: Bool = false) {
        mutateProfile { $0.keepAlive = true }
        consecutiveRestarts = 0
        activateOnNextLaunch = activate
        switch phase {
        case .stopped, .waitingRestart:
            manualLaunchRequested = true
            phase = .waitingRestart(at: Date())
            hub?.tick()
        case .launching, .running, .stopping:
            break
        }
    }

    func stop() {
        invalidateComputerWork()
        restartRequested = false
        manualLaunchRequested = false
        mutateProfile { $0.keepAlive = false }
        guard let app else {
            phase = .stopped
            return
        }
        log("正在停止")
        phase = .stopping
        requestTerminate(app)
    }

    func restart() {
        invalidateComputerWork()
        guard let app else {
            start()
            return
        }
        log("手动重启")
        restartRequested = true
        consecutiveRestarts = 0
        requestTerminate(app)
    }

    func setKeepAlive(_ on: Bool) {
        mutateProfile { $0.keepAlive = on }
        log(on ? "已开启保活" : "已关闭保活：退出后不再自动拉起")
        if !on { cancelAutomaticComputerWork() }
        if on { hub?.tick() }
    }

    /// 总开关不改各 Bot 的配置；取消正在执行的自动工作，恢复后重新检查。
    func keepAlivePauseChanged() {
        cancelAutomaticComputerWork()
        checkEpoch = UUID()
        checkTask?.cancel()
        checkTask = nil
        healthFailures = 0
        lastHealthCheck = .distantPast
        lastAuthCheck = .distantPast
        if keepAlivePaused, case .waitingRestart = phase, !manualLaunchRequested {
            phase = .stopped
        }
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile.name else { return }
        mutateProfile { $0.name = trimmed }
        titleTaggedPID = nil
    }

    /// 把这个实例的窗口带到前台；主窗口被关掉了就先重新打开。
    func showWindow() {
        guard let app else {
            start(activate: true)
            return
        }
        if health == .windowClosed { reopenMainWindow() }
        app.activate(options: [.activateAllWindows])
    }

    /// 主窗口被关掉后（实例仍在后台运行），让它重新显示主窗口。
    private func reopenMainWindow() {
        sendToRunningInstance()
    }

    /// 用同一个数据目录再启动一次 Grok Bot：单实例锁会让新进程立刻退出，并把参数（包括深链）
    /// 转交给这个 Bot 自己的实例，同时把它的窗口带到前台。深链因此只会送到这一个实例。
    private func sendToRunningInstance(deepLink: String? = nil, activate: Bool = true) {
        guard let appURL = GrokBotApp.locate() else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = activate
        // 不带 --remote-debugging-port，避免这个临时进程覆盖 DevToolsActivePort
        config.arguments = ["\(LaunchArguments.userDataDirFlag)=\(profile.dataDir.path)"] + (deepLink.map { [$0] } ?? [])
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }

    func logout() {
        invalidateComputerWork()
        guard let client, !logoutActive else { return }
        let expectedPID = pid
        logoutActive = true
        Task {
            defer { logoutActive = false }
            do {
                try await GrokBotBridge(client: client).logout()
                guard pid == expectedPID else { return }
                log("已退出登录")
                mutateProfile { $0.accountEmail = nil; $0.accountName = nil }
                auth = .loggedOut
                logoutNotified = true
            } catch {
                log("退出登录失败：\(error.localizedDescription)", .error)
            }
        }
    }

    /// 删除前调用：关闭保活、尽量退出账号、结束进程，最多等 20 秒。
    func shutdownForDeletion() async {
        invalidateComputerWork()
        mutateProfile { $0.keepAlive = false }
        hub?.loginWindows.close(for: id)
        if let client, auth == .loggedIn {
            try? await withTimeout(10) { try await GrokBotBridge(client: client).logout() }
        }
        guard let app else { return }
        phase = .stopping
        app.terminate()
        for _ in 0..<40 where !app.isTerminated {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !app.isTerminated { Self.kill(app) }
    }

    // MARK: - 保活：由 HubController 周期调用

    /// 根据扫描到的进程推进状态机。返回是否发起了一次启动（Hub 用它错开多个实例的启动）。
    func reconcile(instance: GrokBotInstance?, now: Date, mayLaunch: Bool) -> Bool {
        if let instance {
            if instance.pid != pid { attach(instance, now: now) }
            if phase != .running, phase != .stopping { phase = .running }
            if let since = runningSince, consecutiveRestarts > 0, restartPolicy.isStable(runningSince: since, now: now) {
                consecutiveRestarts = 0
            }
            if let requested = terminateRequestedAt, now.timeIntervalSince(requested) > Self.terminateTimeout {
                log("正常退出超时，强制结束进程", .warning)
                Self.kill(instance.app)
                terminateRequestedAt = now
            }
            return false
        }

        if app != nil { detach(now: now) }

        switch phase {
        case .running, .stopping:
            phase = .stopped
            return false
        case .launching(let since):
            if now.timeIntervalSince(since) > Self.launchTimeout {
                log("启动超时", .warning)
                scheduleRestart(now: now)
            }
            return false
        case .waitingRestart(let at):
            guard (manualLaunchRequested || keepsProcessAlive), now >= at, mayLaunch else { return false }
            launch(now: now)
            return true
        case .stopped:
            guard keepsProcessAlive, mayLaunch else { return false }
            launch(now: now)
            return true
        }
    }

    /// 已登录时每 3 分钟确认一次；Grok Bot 正在登录时每 3 秒、未登录时每 15 秒看一次，
    /// 这样不管是在管家里登录，还是直接在 Grok Bot 里登录，管家都能很快显示出来。
    private var authInterval: TimeInterval {
        switch auth {
        case .loggedIn: return 180
        case .loggingIn: return 3
        case .loggedOut, .unknown: return 15
        }
    }

    /// 按间隔安排健康检查和登录状态检查。
    func tick(now: Date) {
        scheduleComputerMaintenance(now: now)
        guard !keepAlivePaused, app != nil, phase == .running, checkTask == nil, health != .noDebugPort else { return }
        // 刚启动时每 3 秒试连一次；之后（包括出故障后）按正常间隔检查，卡死判定才是「连续约 2 分钟」
        let dueHealth = now.timeIntervalSince(lastHealthCheck) >= (health == .connecting ? 3 : Self.healthInterval)
        // 登录状态只在连接正常时读；连接本身由健康检查负责，失败也只由它计数
        let dueAuth = health == .ok && !loginActive && now.timeIntervalSince(lastAuthCheck) >= authInterval
        guard dueHealth || dueAuth else { return }
        let epoch = checkEpoch
        checkTask = Task {
            defer { if checkEpoch == epoch { checkTask = nil } }
            await runChecks(health: dueHealth, auth: dueAuth, epoch: epoch)
        }
    }

    // MARK: - 进程生命周期

    private func launch(now: Date) {
        manualLaunchRequested = false
        guard let appURL = GrokBotApp.locate() else {
            log("没有找到 Grok Bot.app，30 秒后再试", .error)
            phase = .waitingRestart(at: now.addingTimeInterval(30))
            return
        }
        try? FileManager.default.createDirectory(at: profile.dataDir, withIntermediateDirectories: true)
        phase = .launching(since: now)
        let activate = activateOnNextLaunch
        activateOnNextLaunch = false
        log("启动 Grok Bot 实例")
        Task {
            do {
                let running = try await GrokBotApp.launchInstance(appURL: appURL, userDataDir: profile.dataDir, activate: activate)
                if app == nil, !running.isTerminated {
                    attach(GrokBotInstance(app: running, userDataDir: profile.dataDir.path, debuggingEnabled: true), now: Date())
                    phase = .running
                }
            } catch {
                log("启动失败：\(error.localizedDescription)", .error)
                scheduleRestart(now: Date())
            }
        }
    }

    private func attach(_ instance: GrokBotInstance, now: Date) {
        if app != nil { invalidateComputerWork() }
        let adopted: Bool
        if case .launching = phase { adopted = false } else { adopted = true }
        app = instance.app
        manualLaunchRequested = false
        runningSince = instance.app.launchDate ?? now
        client = nil
        healthFailures = 0
        lastHealthCheck = .distantPast
        lastAuthCheck = .distantPast
        terminateRequestedAt = nil
        titleTaggedPID = nil
        health = instance.debuggingEnabled ? .connecting : .noDebugPort
        log(adopted ? "接管已在运行的实例（pid \(instance.pid)）" : "实例已启动（pid \(instance.pid)）")
        if !instance.debuggingEnabled {
            log("这个实例启动时没有开调试端口，无法检测登录状态；点「重启」后由管家接管", .warning)
        }
    }

    private func detach(now: Date) {
        invalidateComputerWork()
        let uptime = runningSince.map { now.timeIntervalSince($0) } ?? 0
        app = nil
        client = nil
        runningSince = nil
        health = .unknown
        auth = .unknown
        healthFailures = 0
        terminateRequestedAt = nil

        if phase == .stopping {
            log("已停止")
            phase = .stopped
        } else if restartRequested {
            restartRequested = false
            manualLaunchRequested = true
            phase = .waitingRestart(at: now)
        } else if keepsProcessAlive {
            log("进程退出（运行了 \(Self.describe(uptime))）", .warning)
            scheduleRestart(now: now)
        } else {
            log("进程已退出")
            phase = .stopped
        }
    }

    private func scheduleRestart(now: Date) {
        guard keepsProcessAlive else {
            phase = .stopped
            return
        }
        let delay = restartPolicy.delay(forConsecutiveRestarts: consecutiveRestarts)
        consecutiveRestarts += 1
        autoRestarts += 1
        phase = .waitingRestart(at: now.addingTimeInterval(delay))
        log("\(Int(delay)) 秒后自动拉起（连续第 \(consecutiveRestarts) 次）")
        if consecutiveRestarts == 3 {
            Notifier.post("\(profile.name) 反复退出", "已连续重启 3 次，管家会继续按退避间隔拉起它。")
        }
    }

    private func requestTerminate(_ app: NSRunningApplication) {
        terminateRequestedAt = Date()
        if !app.terminate() { Self.kill(app) }
    }

    /// 强制结束。`NSRunningApplication.forceTerminate()` 对已经卡死（停止响应）的进程不一定生效，直接发 SIGKILL。
    private static func kill(_ app: NSRunningApplication) {
        Darwin.kill(app.processIdentifier, SIGKILL)
    }

    // MARK: - 健康与登录状态

    private func runChecks(health dueHealth: Bool, auth dueAuth: Bool, epoch: UUID) async {
        guard let pid, let since = runningSince else { return }
        let now = Date()
        // 每次 await 之后进程都可能已经换了，旧结果不能写到新进程上
        var stillSameProcess: Bool {
            self.pid == pid && checkEpoch == epoch && !keepAlivePaused && !Task.isCancelled
        }
        guard stillSameProcess else { return }

        if client == nil {
            guard dueHealth else { return }
            lastHealthCheck = now
            do {
                let discovered = try await DevToolsClient.discover(userDataDir: profile.dataDir, expectedPID: pid)
                guard stillSameProcess else { return }
                client = discovered
            } catch {
                // 启动初期端口文件还没写出来，宽限期过后才算故障
                if stillSameProcess, now.timeIntervalSince(since) > hangPolicy.startupGrace { recordHealthFailure(error) }
                return
            }
        }
        guard let client else { return }

        var becameHealthy = false
        if dueHealth || health == .connecting {
            lastHealthCheck = now
            do {
                let target = try await client.mainWindow()
                _ = try await client.evaluate("1", in: target, timeout: 8)
                guard stillSameProcess else { return }
                becameHealthy = health != .ok
                if case .unresponsive = health { log("恢复响应") }
                health = .ok
                healthFailures = 0
            } catch DevToolsError.noMainWindow {
                guard stillSameProcess else { return }
                if health != .windowClosed { log("主窗口已关闭，实例在后台运行") }
                health = .windowClosed
                healthFailures = 0
            } catch {
                guard stillSameProcess else { return }
                if health == .connecting, now.timeIntervalSince(since) < hangPolicy.startupGrace { return }
                // 端口失效时下次重新发现（比如实例被更新器重启过）
                self.client = nil
                recordHealthFailure(error)
                return
            }
        }

        guard stillSameProcess else { return }
        if health == .ok, titleTaggedPID != pid {
            titleTaggedPID = pid
            try? await GrokBotBridge(client: client).tagWindowTitle(profile.name)
        }

        if stillSameProcess, (dueAuth || becameHealthy) && !loginActive {
            await refreshAuth(using: client, isCurrent: { stillSameProcess })
        }
    }

    private func recordHealthFailure(_ error: Error) {
        healthFailures += 1
        health = .unresponsive(failures: healthFailures)
        if healthFailures == 1 {
            log("健康检查失败：\(error.localizedDescription)", .warning)
        }
        guard keepsProcessAlive, HubSettings.restartUnresponsive, let app,
              hangPolicy.shouldRestart(consecutiveFailures: healthFailures, runningSince: runningSince, now: Date()) else { return }
        log("连续 \(healthFailures) 次无响应，强制重启", .error)
        Notifier.post("\(profile.name) 无响应", "已强制结束并自动重新拉起。")
        healthFailures = 0
        Self.kill(app)
    }

    private func refreshAuth(using client: DevToolsClient, isCurrent: @MainActor () -> Bool) async {
        lastAuthCheck = Date()
        let pid = self.pid
        do {
            let status = try await GrokBotBridge(client: client).authStatus()
            guard self.pid == pid, isCurrent() else { return }
            apply(status)
        } catch {
            guard isCurrent() else { return }
            HubLog.write("[\(profile.name)] 读取登录状态失败：\(error.localizedDescription)")
        }
    }

    private func apply(_ status: GrokBotAuthStatus) {
        let previous = auth
        switch status.kind {
        case .loggedIn:
            auth = .loggedIn
            logoutNotified = false
            if previous != .loggedIn {
                log("已登录：\(status.email ?? status.displayName ?? "未知账号")")
            }
            // 刚从未登录 / 登录中变成已登录（包括直接在 Grok Bot 里完成的登录）
            if previous == .loggedOut || previous == .loggingIn {
                mutateProfile { $0.lastLoginAt = Date() }
                if !loginActive {
                    Notifier.post("\(profile.name) 登录成功", status.email ?? "Grok Bot 已登录")
                }
            }
            if status.email != nil || status.displayName != nil {
                mutateProfile {
                    $0.accountEmail = status.email ?? $0.accountEmail
                    $0.accountName = status.displayName ?? $0.accountName
                }
            }
        case .loggedOut:
            if previous != .loggedOut { invalidateComputerWork() }
            auth = .loggedOut
            let wasLoggedIn = previous == .loggedIn || (previous == .unknown && profile.accountEmail != nil)
            if wasLoggedIn, !logoutNotified {
                logoutNotified = true
                log("账号已掉线，需要重新登录", .warning)
                Notifier.post("\(profile.name) 已掉线", "Grok Bot 账号已退出登录，请在管家里重新登录。")
            }
        case .loggingIn:
            auth = .loggingIn
        case .other:
            break
        }
    }

    // MARK: - 登录流程

    /// 自动完成：确保实例运行 → 点「登录」→ 取登录链接 → 在隔离窗口打开 → 等 Grok Bot 拿到 token。
    func beginLogin() {
        guard !loginActive else {
            hub?.loginWindows.focus(id)
            return
        }
        invalidateComputerWork()
        loginActive = true
        log("开始登录流程")
        if !profile.keepAlive || app == nil { start() }
        Task {
            do {
                try await runLogin()
            } catch {
                log("登录未完成：\(error.localizedDescription)", .error)
            }
            hub?.loginWindows.close(for: id)
            loginActive = false
        }
    }

    private func runLogin() async throws {
        guard GrokBotApp.locate() != nil else { throw LoginError.grokBotMissing }
        var bridge = try await waitForBridge(timeout: 120)

        let status = try await bridge.authStatus()
        if status.kind == .loggedIn {
            apply(status)
            log("已经是登录状态，无需重新登录")
            return
        }

        // 新发起的登录，Grok Bot 会自己在默认浏览器里打开登录页
        var grokBotOpenedBrowser = false
        if try await bridge.loginFlight() != .waitingForBrowser {
            try await bridge.startLogin()
            grokBotOpenedBrowser = true
        }
        try await waitUntil(timeout: 20) { try await bridge.loginFlight() == .waitingForBrowser }

        let copied = try await PasteboardCapture.captureString {
            guard try await bridge.copyLoginLink() == "copied" else { throw LoginError.noLink }
        }
        guard let url = copied.flatMap(LoginLink.validate) else { throw LoginError.noLink }

        hub?.loginWindows.open(for: self, url: url, browserAlreadyOpen: grokBotOpenedBrowser)
        log(HubSettings.loginMode == .browser ? "已在默认浏览器打开登录页" : "已在全新会话中打开登录页")

        let deadline = Date().addingTimeInterval(Self.loginTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard hub?.loginWindows.isOpen(id) == true else {
                try? await bridge.cancelLogin()
                throw LoginError.cancelled
            }
            guard let client else { continue }   // 实例重启中，等它回来
            bridge = GrokBotBridge(client: client)
            guard let current = try? await bridge.authStatus() else { continue }
            if current.kind == .loggedIn {
                apply(current)
                mutateProfile { $0.lastLoginAt = Date() }
                Notifier.post("\(profile.name) 登录成功", current.email ?? "Grok Bot 已登录")
                showWindow()
                return
            }
            if current.kind == .loggedOut, (try? await bridge.loginFlight()) == .idle {
                throw LoginError.cancelled   // 在 Grok Bot 窗口里点了取消，或 Grok Bot 自己超时
            }
        }
        try? await bridge.cancelLogin()
        throw LoginError.timedOut
    }

    private func waitForBridge(timeout: TimeInterval, isCurrent: @MainActor () -> Bool = { true }) async throws -> GrokBotBridge {
        let deadline = Date().addingTimeInterval(timeout)
        var reopenedWindow = false
        while Date() < deadline {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if health == .noDebugPort { throw LoginError.noDebugPort }
            if let pid, client == nil {
                let discovered = try? await DevToolsClient.discover(userDataDir: profile.dataDir, expectedPID: pid)
                guard isCurrent(), self.pid == pid else { throw CancellationError() }
                client = discovered
            }
            if let client {
                do {
                    _ = try await client.mainWindow()
                    let bridge = GrokBotBridge(client: client)
                    if (try? await bridge.isReady()) == true {
                        guard isCurrent() else { throw CancellationError() }
                        return bridge
                    }
                } catch DevToolsError.noMainWindow {
                    // 登录要通过主窗口操作。刚启动的实例窗口还没建好，再等等；运行一阵后还没有就是被关掉了
                    let settled = runningSince.map { Date().timeIntervalSince($0) > 20 } ?? false
                    if settled, !reopenedWindow {
                        reopenedWindow = true
                        log("Grok Bot 主窗口已关闭，正在重新打开")
                        reopenMainWindow()
                    }
                } catch {
                    // 调试端口暂时连不上，下一轮再试
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw LoginError.notReady
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await condition()) == true { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LoginError.notReady
    }

    // MARK: - 电脑巡检与恢复

    private static let computerPaneLink = "grokbot://app/v1/sidebar?tab=computer"

    enum ComputerError: LocalizedError {
        case screenLocked, cannotActivate, activationInterrupted, notLoggedIn, paused, notShown, timedOut
        case stuck(ComputerState)

        var errorDescription: String? {
            switch self {
            case .screenLocked: return "这台 Mac 已锁屏，解锁后自动继续检查和恢复电脑"
            case .cannotActivate: return "没能把这个 Bot 的窗口带到前台，稍后会重试"
            case .activationInterrupted: return "窗口已显示，但前台轮换被打断；稍后会自动重试"
            case .notLoggedIn: return "这个 Bot 尚未登录，请先完成登录"
            case .paused: return "Grok Bot 显示电脑正在重建或已暂时暂停，管家会继续检查，等待服务恢复"
            case .notShown: return "没找到电脑画面，请在 Grok Bot 里确认这个 Bot 已配置电脑"
            case .timedOut: return "120 秒内未确认电脑恢复，稍后会重试"
            case .stuck(let state): return BotController.stuckMessage(state)
            }
        }
    }

    private var automaticComputerMaintenanceEnabled: Bool {
        keepsComputerAwake && isRunning
            && phase == .running && auth == .loggedIn && !loginActive && !logoutActive
            && terminateRequestedAt == nil && !restartRequested && app?.isTerminated == false
    }

    private func scheduleComputerMaintenance(now: Date) {
        guard keepsComputerAwake else {
            cancelAutomaticComputerWork()
            return
        }
        guard automaticComputerMaintenanceEnabled, computerTask == nil, !wakeActive,
              computerSchedule.isDue(at: now) else { return }
        guard health == .ok || health == .windowClosed else { return }
        computerSchedule.inspected(at: now)
        guard !isMacScreenLocked() else {
            setComputerIssue(ComputerError.screenLocked.localizedDescription)
            return
        }

        let epoch = computerEpoch
        computerTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.computerEpoch == epoch { self.computerTask = nil } }
            @MainActor func isCurrent() -> Bool {
                self.computerEpoch == epoch && self.automaticComputerMaintenanceEnabled && !Task.isCancelled
            }
            do {
                // 关掉主窗口后先走恢复流程，避免在后台检查时抢走其他 Bot 的前台。
                if self.health == .windowClosed {
                    guard self.computerSchedule.needsRecovery(for: .notShown, at: Date()) else { return }
                    if let token = await self.beginWake(automatic: true) { await self.finishWake(token) }
                    return
                }
                let bridge = try await self.waitForBridge(timeout: 30, isCurrent: isCurrent)
                let state = try await bridge.computerState()
                guard isCurrent(), !self.wakeActive else { return }
                guard !isMacScreenLocked() else { throw ComputerError.screenLocked }
                self.recordComputerState(state, at: Date())
                if state == .paused {
                    self.setComputerIssue(ComputerError.paused.localizedDescription)
                    self.computerRetryAt = nil
                    return
                }
                if self.computerSchedule.needsRecovery(for: state, at: Date()) {
                    if let token = await self.beginWake(automatic: true) { await self.finishWake(token) }
                } else if state == .onDevice || (state == .awake && Date() < self.computerSchedule.nextActivationAt) {
                    self.computerIssue = nil
                    self.computerRetryAt = nil
                    self.computerSchedule.completed(success: true, at: Date())
                }
            } catch is CancellationError {
                // 停止、重启、退出登录、关闭开关后，旧巡检结果不能再写回来。
            } catch {
                guard isCurrent() else { return }
                self.recordComputerFailure(error)
            }
        }
    }

    func openComputerPane() {
        sendToRunningInstance(deepLink: Self.computerPaneLink)
    }

    /// 已有电脑画面时直接聚焦正确实例；只有需要导航时才转交深链。
    func prepareComputerWindow(isCurrent: @MainActor () -> Bool) async throws {
        guard isCurrent() else { throw CancellationError() }
        if let client {
            let bridge = GrokBotBridge(client: client)
            do {
                let state = try await bridge.computerState()
                guard isCurrent() else { throw CancellationError() }
                recordComputerState(state, at: Date())
                if state == .notShown {
                    // 临时转发进程不抢前台，真正的 Bot 自己显示窗口。
                    sendToRunningInstance(deepLink: Self.computerPaneLink, activate: false)
                }
                try await bridge.focusWindow()
                guard isCurrent() else { throw CancellationError() }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isCurrent() else { throw CancellationError() }
                log("窗口接口暂不可用，改用系统方式打开电脑页", .warning)
            }
        }
        openComputerPane()
    }

    func restoreWindowThroughWorkspace() {
        sendToRunningInstance()
    }

    func computerWasActivated(at now: Date) {
        computerForegroundNote = nil
        lastComputerActivationAt = now
        computerSchedule.activated(at: now)
        log("已确认 Bot 窗口到达前台，3 分钟后再次轮换")
    }

    /// 手动和自动共用同一条恢复流程，每个 Bot 同时最多执行一次。
    func wakeComputer() async {
        guard let token = await beginWake() else { return }
        await finishWake(token)
    }

    private func wakeIsCurrent(_ token: UUID) -> Bool {
        wakeToken == token && !Task.isCancelled && !loginActive && !logoutActive && phase != .stopping
            && terminateRequestedAt == nil && !restartRequested
            && (wakePID == nil || wakePID == pid)
            && (!wakeAutomatic || automaticComputerMaintenanceEnabled)
    }

    /// 每次恢复带独立令牌；进程变化或用户停止后，所有 await 后的操作都要重新核对令牌。
    func beginWake(automatic: Bool = false) async -> UUID? {
        guard !wakeActive else { return nil }
        if !automatic { cancelAutomaticComputerWork() }
        guard !automatic || automaticComputerMaintenanceEnabled else { return nil }
        guard !isMacScreenLocked() else {
            setComputerIssue(ComputerError.screenLocked.localizedDescription)
            return nil
        }
        let token = UUID()
        wakeToken = token
        wakeAutomatic = automatic
        wakePID = pid
        wakeNeededRecovery = computerState?.isAvailable != true
        wakeActive = true
        computerRetryAt = nil
        log(automatic ? "自动检查并恢复电脑" : "手动唤醒电脑")
        do {
            if app == nil { start() }
            // 等待进程启动不占用前台轮换锁，一台启动缓慢不会拖住其他 Bot。
            let launchDeadline = Date().addingTimeInterval(120)
            while pid == nil, Date() < launchDeadline {
                guard wakeIsCurrent(token) else { throw CancellationError() }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard wakeIsCurrent(token) else { throw CancellationError() }
            guard pid != nil, let hub else { throw LoginError.notReady }
            wakePID = pid
            try await hub.focusComputer(self, isCurrent: { self.wakeIsCurrent(token) })
            let bridge = try await waitForBridge(timeout: 30, isCurrent: { self.wakeIsCurrent(token) })
            let status = try await bridge.authStatus()
            guard wakeIsCurrent(token) else { throw CancellationError() }
            guard status.kind == .loggedIn else {
                apply(status)
                throw ComputerError.notLoggedIn
            }
            apply(status)
            return token
        } catch is CancellationError {
            clearWake(token)
            return nil
        } catch {
            if wakeToken == token {
                recordComputerFailure(error)
                clearWake(token)
            }
            return nil
        }
    }

    /// 睡着就点唤醒，连接失败就重试，屏幕暂停就重新激活；每种操作每轮最多两次。
    func finishWake(_ token: UUID, timeout: TimeInterval = 120) async {
        defer { clearWake(token) }
        let start = Date()
        var last: ComputerState?
        var since = start
        var lastAction = Date.distantPast
        var tries: [ComputerState: Int] = [:]
        var readError: Error?
        do {
            while Date().timeIntervalSince(start) < timeout {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard wakeIsCurrent(token) else { throw CancellationError() }
                guard !isMacScreenLocked() else { throw ComputerError.screenLocked }
                guard let client else { throw LoginError.noDebugPort }
                let bridge = GrokBotBridge(client: client)
                let state: ComputerState
                do {
                    state = try await bridge.computerState()
                } catch {
                    readError = error
                    continue
                }
                guard wakeIsCurrent(token) else { throw CancellationError() }
                guard !isMacScreenLocked() else { throw ComputerError.screenLocked }
                let now = Date()
                recordComputerState(state, at: now)
                if state != last {
                    last = state
                    since = now
                }
                switch state {
                case .awake, .onDevice:
                    computerSchedule.completed(success: true, at: now)
                    computerRetryAt = nil
                    computerIssue = nil
                    if wakeAutomatic, wakeNeededRecovery { autoComputerRecoveries += 1 }
                    log(state == .onDevice ? "电脑在此设备上运行" : "已确认电脑运行中")
                    return
                case .paused:
                    throw ComputerError.paused
                case .waking:
                    continue
                case .notShown:
                    if now.timeIntervalSince(since) >= 15 { throw ComputerError.notShown }
                case .asleep, .unreachable, .away, .unrecognizedFullscreen:
                    guard now.timeIntervalSince(lastAction) >= 8,
                          state != .away || now.timeIntervalSince(since) >= 8 else { continue }
                    guard tries[state, default: 0] < 2 else { throw ComputerError.stuck(state) }
                    tries[state, default: 0] += 1
                    lastAction = now
                    try await act(on: state, bridge, token: token)
                }
            }
            throw last == nil ? (readError ?? ComputerError.timedOut) : ComputerError.timedOut
        } catch is CancellationError {
            // 用户的停止、重启和关闭开关优先，取消不算一次恢复失败。
        } catch {
            guard wakeToken == token else { return }
            recordComputerFailure(error)
        }
    }

    private func act(on state: ComputerState, _ bridge: GrokBotBridge, token: UUID) async throws {
        guard wakeIsCurrent(token) else { throw CancellationError() }
        guard !isMacScreenLocked() else { throw ComputerError.screenLocked }
        switch state {
        case .asleep:
            if try await bridge.clickWakeComputer() {
                log("已点击「唤醒电脑」")
            } else {
                log("电脑在休眠，但没找到能点的「唤醒电脑」按钮", .warning)
            }
        case .unreachable:
            if try await bridge.clickRetry() {
                log("Grok Bot 显示连不上屏幕，已点击「重试」")
            } else {
                try await hub?.focusComputer(self, isCurrent: { self.wakeIsCurrent(token) })
            }
        case .away:
            log("屏幕已暂停，重新把 Bot 窗口带到前台")
            try await hub?.focusComputer(self, isCurrent: { self.wakeIsCurrent(token) })
        case .unrecognizedFullscreen:
            if try await bridge.exitComputerFullscreen() {
                log("全屏电脑画面里认不出状态，已退出全屏")
            }
        default:
            break
        }
    }

    nonisolated private static func stuckMessage(_ state: ComputerState) -> String {
        switch state {
        case .asleep: "点了两次「唤醒电脑」仍在休眠，稍后自动重试"
        case .unreachable: "Grok Bot 仍然连不上电脑屏幕，稍后自动重试"
        case .away: "窗口已到前台，但 Grok Bot 仍显示屏幕暂停，稍后自动重试"
        case .unrecognizedFullscreen: "仍无法识别全屏电脑状态，请在 Grok Bot 里检查电脑画面"
        default: "未确认电脑运行，稍后自动重试"
        }
    }

    private func recordComputerState(_ state: ComputerState, at now: Date) {
        computerState = state
        computerCheckedAt = now
        if state == .onDevice { computerForegroundNote = nil }
    }

    private func setComputerIssue(_ message: String) {
        if computerIssue != message { log(message, .warning) }
        computerIssue = message
    }

    private func recordComputerFailure(_ error: Error) {
        let now = Date()
        if let reason = error as? ComputerError, case .activationInterrupted = reason {
            computerSchedule.deferActivation(at: now)
            computerRetryAt = computerSchedule.nextRecoveryAt
            let message = reason.localizedDescription
            if computerForegroundNote != message { log(message, .warning) }
            computerForegroundNote = message
            if computerState?.isAvailable == true,
               computerCheckedAt.map({ now.timeIntervalSince($0) <= 90 }) == true {
                computerIssue = nil
            } else {
                setComputerIssue(message)
            }
            return
        }
        computerForegroundNote = nil
        computerSchedule.completed(success: false, at: now)
        computerRetryAt = computerSchedule.nextRecoveryAt
        setComputerIssue(error.localizedDescription)
    }

    private func clearWake(_ token: UUID) {
        guard wakeToken == token else { return }
        wakeToken = nil
        wakePID = nil
        wakeAutomatic = false
        wakeActive = false
    }

    private func cancelAutomaticComputerWork() {
        guard !wakeActive || wakeAutomatic else { return }
        computerEpoch = UUID()
        computerTask?.cancel()
        computerTask = nil
        if let token = wakeToken { clearWake(token) }
        computerSchedule = ComputerMaintenanceSchedule()
        computerRetryAt = nil
        computerForegroundNote = nil
    }

    private func invalidateComputerWork() {
        computerEpoch = UUID()
        computerTask?.cancel()
        computerTask = nil
        if let token = wakeToken { clearWake(token) }
        computerSchedule = ComputerMaintenanceSchedule()
        computerState = nil
        computerCheckedAt = nil
        computerIssue = nil
        computerForegroundNote = nil
        computerRetryAt = nil
        lastComputerActivationAt = nil
    }

    // MARK: - 工具

    private func mutateProfile(_ change: (inout BotProfile) -> Void) {
        var copy = profile
        change(&copy)
        guard copy != profile else { return }
        profile = copy
        hub?.persist()
    }

    func log(_ message: String, _ level: Event.Level = .info) {
        events.insert(Event(date: Date(), level: level, message: message), at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
        HubLog.write("[\(profile.name)/\(id)] \(message)")
    }

    static func describe(_ interval: TimeInterval) -> String {
        let s = Int(max(0, interval))
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分钟" }
        if s < 86400 { return "\(s / 3600) 小时 \(s % 3600 / 60) 分" }
        return "\(s / 86400) 天 \(s % 86400 / 3600) 小时"
    }
}
