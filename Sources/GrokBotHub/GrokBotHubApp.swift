import SwiftUI

@main
struct GrokBotHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let hub = HubController.shared

    var body: some Scene {
        Window("Grok Bot Hub", id: "main") {
            MainView()
                .environment(hub)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1000, height: 660)

        Settings {
            SettingsView().environment(hub)
        }

        MenuBarExtra {
            MenuBarContent().environment(hub)
        } label: {
            MenuBarLabel().environment(hub)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let suppressQuitWarning = "suppressQuitWarning"

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { HubController.shared.start() }
    }

    /// 关掉主窗口后继续在菜单栏里保活。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let keepAliveCount = MainActor.assumeIsolated {
            HubController.shared.bots.filter { $0.profile.keepAlive && $0.isRunning }.count
        }
        guard keepAliveCount > 0, !UserDefaults.standard.bool(forKey: Self.suppressQuitWarning) else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "退出管家后保活会暂停"
        alert.informativeText = "\(keepAliveCount) 个 Bot 会继续运行，但退出、崩溃或掉线后不会再被自动拉起。下次打开管家时会重新接管它们。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再提示"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.suppressQuitWarning)
        }
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
