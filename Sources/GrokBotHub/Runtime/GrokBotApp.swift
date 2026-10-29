import AppKit
import Carbon
import HubCore

/// 本机安装的 Grok Bot.app。
enum GrokBotApp {
    static let bundleID = "com.anysphere.sand"
    static let downloadPage = URL(string: "https://x.ai/bot")!

    static func locate() -> URL? {
        let fm = FileManager.default
        if let custom = HubSettings.grokBotAppPath, fm.fileExists(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/Grok Bot.app")
        return fm.fileExists(atPath: fallback.path) ? fallback : nil
    }

    static func version(at url: URL) -> String? {
        Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// 通过 LaunchServices 新开一个实例。
    ///
    /// 不能用 posix_spawn / Process 直接起子进程：那样 macOS 会把麦克风、录屏、辅助功能等
    /// 权限记到宿主名下，Grok Bot 在本机做电脑操作时就拿不到自己的授权。
    static func launchInstance(appURL: URL, userDataDir: URL, activate: Bool) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = LaunchArguments.make(userDataDir: userDataDir.path)
        config.activates = activate
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        return try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }

    /// 给已接管的进程发送系统重开事件，不再启动临时转发进程。
    /// 同目录的 Electron 单实例锁在更新或异常时可能失效，不能靠再次启动来转发。
    static func reopenRunningInstance(_ app: NSRunningApplication) throws {
        guard app.bundleIdentifier == bundleID, !app.isTerminated else {
            throw CocoaError(.executableNotLoadable)
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        _ = try event.sendEvent(options: [.noReply, .neverInteract], timeout: 2)
        app.activate(options: [.activateAllWindows])
    }

    /// Grok Bot 进入 App Nap 后计时器和网络会被节流。这个偏好写在 Grok Bot 自己的 defaults 域里，
    /// 对所有实例生效，实例下次启动时读取。
    static func applyAppNapPreference(disabled: Bool) {
        let key = "NSAppSleepDisabled" as CFString
        let domain = bundleID as CFString
        CFPreferencesSetAppValue(key, disabled ? kCFBooleanTrue : nil, domain)
        CFPreferencesAppSynchronize(domain)
    }
}

/// 一个正在运行的 Grok Bot 主进程。
struct GrokBotInstance {
    let app: NSRunningApplication
    let userDataDir: String?
    let debuggingEnabled: Bool

    var pid: pid_t { app.processIdentifier }
}

enum InstanceScanner {
    /// 枚举所有 Grok Bot 主进程（Helper 进程的 bundle id 不同，不会混进来）。
    static func scan() -> [GrokBotInstance] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == GrokBotApp.bundleID && !$0.isTerminated }
            .map { app in
                let args = processArguments(app.processIdentifier) ?? []
                return GrokBotInstance(
                    app: app,
                    userDataDir: LaunchArguments.userDataDir(in: args),
                    debuggingEnabled: LaunchArguments.hasRemoteDebugging(in: args)
                )
            }
    }

    static func processArguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        let ok = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) } == 0
        guard ok else { return nil }
        return LaunchArguments.parseProcArgs(Array(buffer.prefix(size)))
    }
}
