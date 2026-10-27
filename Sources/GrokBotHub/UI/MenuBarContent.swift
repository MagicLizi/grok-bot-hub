import SwiftUI

struct MenuBarLabel: View {
    @Environment(HubController.self) private var hub

    var body: some View {
        let symbol = hub.keepAlivePaused ? "pause.circle"
            : hub.attentionCount > 0 ? "exclamationmark.triangle" : "square.stack.3d.up"
        Image(systemName: symbol)
        Text("\(hub.runningCount)")
    }
}

struct MenuBarContent: View {
    @Environment(HubController.self) private var hub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(hub.runningCount)/\(hub.bots.count) 个 Bot 运行中")
        Text("\(hub.awakeComputerCount) 台电脑已确认运行")
        Button { hub.toggleKeepAlive() } label: {
            Label(hub.keepAlivePaused ? "开启保活" : "暂停保活",
                  systemImage: hub.keepAlivePaused ? "play.circle" : "pause.circle")
        }
        Divider()
        ForEach(hub.bots) { bot in
            let status = BotStatus(bot)
            Menu("\(bot.profile.name) — \(status.text)") {
                Button("显示窗口") { bot.showWindow() }
                if bot.auth != .loggedIn { Button("登录…") { bot.beginLogin() } }
                Button(bot.wakeActive ? "唤醒中…" : "唤醒电脑") { Task { await bot.wakeComputer() } }
                    .disabled(bot.wakeActive || (bot.auth != .loggedIn && bot.profile.accountEmail == nil))
                Button("重启") { bot.restart() }
                if bot.isRunning {
                    Button("停止") { bot.stop() }
                } else {
                    Button("启动") { bot.start() }
                }
            }
        }
        if !hub.bots.isEmpty { Divider() }
        Button("打开管家…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Button("全部启动") { hub.startAll() }
            .disabled(hub.bots.isEmpty)
        Button(hub.wakingAll ? "正在全部唤醒…" : "全部唤醒") { Task { await hub.wakeAll() } }
            .disabled(hub.wakingAll || hub.wakeableBots.isEmpty)
        Divider()
        SettingsLink { Text("设置…") }
            .keyboardShortcut(",")
        Button("退出 Grok Bot Hub") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
