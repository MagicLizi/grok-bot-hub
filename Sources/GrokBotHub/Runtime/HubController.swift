import AppKit
import HubCore
import Observation
import ServiceManagement

/// 管家总调度：持有所有 Bot，定时扫描进程并推进每个 Bot 的状态机。
@Observable
@MainActor
final class HubController {
    static let shared = HubController()

    private(set) var bots: [BotController] = []
    private(set) var grokBotURL: URL?
    private(set) var grokBotVersion: String?
    /// 不归管家管的 Grok Bot 进程数（比如用户直接双击打开的默认实例）
    private(set) var unmanagedInstances = 0
    private(set) var sleepPrevented = false
    private(set) var displayKeptAwake = false
    private(set) var wakingAll = false
    private(set) var keepingComputersAwake = true

    let loginWindows = LoginWindowManager()

    @ObservationIgnored private let sleepGuard = SleepGuard()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastLaunchAt = Date.distantPast
    @ObservationIgnored private var lastAppLookup = Date.distantPast
    @ObservationIgnored private var started = false
    @ObservationIgnored private var computerForegroundBusy = false

    private static let tickInterval: TimeInterval = 2
    /// 两次实例启动之间至少间隔这么久，避免同时拉起一堆 Electron 把机器卡住
    private static let launchSpacing: TimeInterval = 3

    var runningCount: Int { bots.filter(\.isRunning).count }
    var attentionCount: Int { bots.filter { $0.needsAttention }.count }
    var awakeComputerCount: Int { bots.filter { $0.computerConfirmedAwake }.count }

    func start() {
        guard !started else { return }
        started = true
        HubSettings.register()
        HubPaths.ensureDirectories()
        HubLog.write("管家启动")

        bots = ProfileStore.load().map { BotController(profile: $0, hub: self) }
        // 管家自己的计时器不能被 App Nap 节流
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "监控并保活 Grok Bot 实例"
        )
        applySettings()
        Notifier.requestAuthorization()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == GrokBotApp.bundleID else { return }
                MainActor.assumeIsolated { self?.tick() }
            })
        }
        // 睡眠唤醒后立刻巡检一遍
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })

        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.5
        tick()

        #if DEBUG
        // 自测入口：open --env GROKBOTHUB_SELFTEST_NEW_BOT=<名字> 启动时直接走登录流程（同名 Bot 已存在则对它重新登录）
        if let name = ProcessInfo.processInfo.environment["GROKBOTHUB_SELFTEST_NEW_BOT"] {
            if let existing = bots.first(where: { $0.profile.name == name }) {
                existing.beginLogin()
            } else {
                createBot(name: name, loginNow: true)
            }
        }
        // open --env GROKBOTHUB_SELFTEST_SNAPSHOT=<秒> 启动若干秒后把窗口内容存到日志目录
        if let delay = ProcessInfo.processInfo.environment["GROKBOTHUB_SELFTEST_SNAPSHOT"].flatMap(Double.init) {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.loginWindows.debugSnapshots(into: HubPaths.logsDir) }
            }
        }
        #endif
    }

    func tick() {
        let now = Date()
        if now.timeIntervalSince(lastAppLookup) > 30 || grokBotURL == nil {
            lastAppLookup = now
            grokBotURL = GrokBotApp.locate()
            grokBotVersion = grokBotURL.flatMap(GrokBotApp.version(at:))
        }

        let instances = InstanceScanner.scan()
        var claimed = Set<pid_t>()
        var launched = false
        for bot in bots {
            let matches = instances.filter { instance in
                instance.userDataDir.map {
                    ProfileMatcher.matches(processDir: $0, profileDir: bot.profile.dataDir,
                                           profileID: bot.id, hubFolderName: HubPaths.folderName)
                } ?? false
            }
            matches.forEach { claimed.insert($0.pid) }
            // 同一目录可能短暂出现两个进程（单实例锁让后来的那个马上退出），优先认已经接管的那个
            let instance = matches.first { $0.pid == bot.pid } ?? matches.first
            let mayLaunch = !launched && grokBotURL != nil && now.timeIntervalSince(lastLaunchAt) >= Self.launchSpacing
            if bot.reconcile(instance: instance, now: now, mayLaunch: mayLaunch) {
                launched = true
                lastLaunchAt = now
            }
            bot.tick(now: now)
        }
        unmanagedInstances = instances.filter { !claimed.contains($0.pid) }.count

        let running = bots.contains(where: \.isRunning)
        sleepGuard.update(!running ? nil
                          : HubSettings.keepDisplayAwake ? .display
                          : HubSettings.preventSleep ? .system : nil)
        sleepPrevented = sleepGuard.isHolding
        displayKeptAwake = sleepGuard.mode == .display
    }

    func persist() {
        ProfileStore.save(bots.map(\.profile))
    }

    func applySettings() {
        keepingComputersAwake = HubSettings.keepComputersAwake
        GrokBotApp.applyAppNapPreference(disabled: HubSettings.disableGrokBotAppNap)
        lastAppLookup = .distantPast
        tick()
    }

    // MARK: - Bot 管理

    func suggestedName() -> String {
        let existing = Set(bots.map(\.profile.name))
        var n = bots.count + 1
        while existing.contains("Bot \(n)") { n += 1 }
        return "Bot \(n)"
    }

    @discardableResult
    func createBot(name: String, loginNow: Bool) -> BotController {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = BotProfile.make(name: trimmed.isEmpty ? suggestedName() : trimmed)
        try? FileManager.default.createDirectory(at: profile.dataDir, withIntermediateDirectories: true)
        let bot = BotController(profile: profile, hub: self)
        bots.append(bot)
        persist()
        bot.log("已创建，数据目录：\(profile.dataDir.path)")
        if loginNow {
            bot.beginLogin()
        } else {
            bot.start()
        }
        return bot
    }

    func delete(_ bot: BotController) async {
        bot.log("正在删除")
        await bot.shutdownForDeletion()
        bots.removeAll { $0.id == bot.id }
        persist()
        // 进程退出后单实例锁文件才释放，稍等再移到废纸篓
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        do {
            try FileManager.default.trashItem(at: bot.profile.dataDir, resultingItemURL: nil)
        } catch {
            HubLog.write("移除数据目录失败：\(error.localizedDescription)")
        }
        removeEmbeddedBrowserData(for: bot.profile.webStoreID)
        HubLog.write("已删除 \(bot.profile.name)（\(bot.id)）")
    }

    /// 删除内置浏览器为这个 Bot 存的网页数据（只有用过内置浏览器登录才会有）。
    /// 不用 `WKWebsiteDataStore.remove(forIdentifier:)`：在本进程没加载过这个数据存储时，它会在 WebKit 内部崩溃。
    private func removeEmbeddedBrowserData(for storeID: UUID) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKit/\(bundleID)/WebsiteDataStore", isDirectory: true)
        for name in Set([storeID.uuidString, storeID.uuidString.lowercased()]) {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            do {
                try FileManager.default.removeItem(at: dir)
            } catch {
                HubLog.write("移除登录网页数据失败：\(error.localizedDescription)")
            }
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        bots.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func startAll() { bots.forEach { $0.start() } }
    func stopAll() { bots.forEach { $0.stop() } }

    /// 可以手动唤醒电脑的 Bot：已登录，且正在运行或开着保活（不替你启动已停止的 Bot）。
    var wakeableBots: [BotController] {
        bots.filter { ($0.isRunning || $0.profile.keepAlive) && ($0.auth == .loggedIn || $0.profile.accountEmail != nil) }
    }

    /// 前台操作串行，电脑恢复并行，避免某一台启动缓慢拖住其他 Bot。
    func wakeAll() async {
        guard !wakingAll else { return }
        guard !isMacScreenLocked() else {
            let reason = "这台 Mac 处于锁屏状态，Grok Bot 不会在锁屏时唤醒电脑。请先解锁再点唤醒"
            wakeableBots.forEach { $0.log(reason, .warning) }
            Notifier.post("没有唤醒", reason)
            return
        }
        wakingAll = true
        defer { wakingAll = false }
        HubLog.write("全部唤醒：\(wakeableBots.count) 个 Bot")
        let drives = wakeableBots.map { bot in Task { await bot.wakeComputer() } }
        for drive in drives { await drive.value }
    }

    /// 所有自动轮换和手动唤醒共用这把锁。只在 Bot 真的到了前台并停留后记录轮换成功。
    func focusComputer(_ bot: BotController, isCurrent: @MainActor () -> Bool) async throws {
        while computerForegroundBusy {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        try Task.checkCancellation()
        guard isCurrent(), bots.contains(where: { $0 === bot }), let pid = bot.pid else { throw CancellationError() }
        guard !isMacScreenLocked() else { throw BotController.ComputerError.screenLocked }
        computerForegroundBusy = true
        let previous = NSWorkspace.shared.frontmostApplication
        defer { computerForegroundBusy = false }
        var failure: Error?
        do {
            try await bot.prepareComputerWindow(isCurrent: { isCurrent() && bot.pid == pid })
            var attempt = ForegroundActivationAttempt(targetPID: pid, startedAt: ProcessInfo.processInfo.systemUptime)
            activation: while true {
                try Task.checkCancellation()
                guard isCurrent(), bot.pid == pid else { throw CancellationError() }
                guard !isMacScreenLocked() else { throw BotController.ComputerError.screenLocked }
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                switch attempt.observe(frontmostPID: frontmostPID, at: ProcessInfo.processInfo.systemUptime) {
                case .confirmed:
                    bot.computerWasActivated(at: Date())
                    break activation
                case .timedOut:
                    bot.log("窗口激活未完成：目标 pid \(pid)，前台 pid \(frontmostPID ?? -1)", .warning)
                    throw BotController.ComputerError.cannotActivate
                case .interrupted:
                    bot.log("前台轮换中断：目标 pid \(pid)，前台 pid \(frontmostPID ?? -1)", .warning)
                    throw BotController.ComputerError.activationInterrupted
                case .waiting:
                    break
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        } catch {
            failure = error
        }
        await restoreForeground(previous, replacing: pid, bot: bot)
        if let failure { throw failure }
    }

    /// activate() 是异步请求，确认切回后才允许下一台开始，避免下一台记住临时的 Bot 窗口。
    private func restoreForeground(_ previous: NSRunningApplication?, replacing pid: pid_t, bot: BotController) async {
        // 用户在轮换期间切到别的程序时，保留用户自己的选择。
        guard let previous, !previous.isTerminated, previous.processIdentifier != pid,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        if !previous.activate(options: []) {
            // 后台应用直接 activate() 可能被 macOS 拒绝，改走 LaunchServices。
            if let managed = bots.first(where: { $0.pid == previous.processIdentifier }) {
                // 多开的 Grok Bot 必须带回它自己的数据目录，不能打开默认实例。
                managed.restoreWindowThroughWorkspace()
            } else if let url = previous.bundleURL, let bundleID = previous.bundleIdentifier,
                      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count == 1 {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = false
                config.activates = true
                config.addsToRecentItems = false
                config.promptsUserIfNeeded = false
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                } catch {
                    bot.log("轮换结束，切回原窗口失败：\(error.localizedDescription)", .warning)
                    return
                }
            } else {
                bot.log("轮换结束，系统未允许切回原窗口", .warning)
                return
            }
        }
        for _ in 0..<20 {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmost == previous.processIdentifier {
                bot.log("轮换结束，已切回原窗口")
                return
            }
            if let frontmost, frontmost != pid {
                let frontApp = NSWorkspace.shared.frontmostApplication
                let isForwardingProcess = frontApp?.bundleIdentifier == GrokBotApp.bundleID
                    && !bots.contains(where: { $0.pid == frontmost })
                if !isForwardingProcess { return }
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
        bot.log("轮换结束，尚未确认原窗口回到前台", .warning)
    }

    // MARK: - 开机启动

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                HubLog.write("设置开机启动失败：\(error.localizedDescription)")
            }
        }
    }
}

extension BotController {
    /// 需要用户留意：未登录、无响应或在等待重启。
    var needsAttention: Bool {
        if case .waitingRestart = phase { return true }
        if case .unresponsive = health { return true }
        if computerIssue != nil, keepsComputerAwake, isRunning { return true }
        if health == .noDebugPort, keepsComputerAwake, isRunning { return true }
        return isRunning && auth == .loggedOut && !loginActive
    }
}
