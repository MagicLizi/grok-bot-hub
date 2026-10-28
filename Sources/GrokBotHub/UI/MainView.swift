import SwiftUI

struct MainView: View {
    @Environment(HubController.self) private var hub
    @ViewState private var selection: String?
    @ViewState private var showingNewBot = false

    var body: some View {
        // 分栏里的原生列表不会可靠地避让外层 safeAreaInset，提示栏直接参与布局。
        VStack(spacing: 0) {
            if hub.keepAlivePaused { KeepAlivePausedBanner() }
            if hub.grokBotURL == nil { MissingGrokBotBanner() }
            if hub.keepAlivePaused || hub.grokBotURL == nil { Divider() }

            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                if let bot = hub.bots.first(where: { $0.id == selection }) {
                    BotDetailView(bot: bot)
                        .id(bot.id)
                } else if hub.bots.isEmpty {
                    ContentUnavailableView {
                        Label("还没有 Bot", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("每个 Bot 是一个独立的 Grok Bot 实例，有自己的账号和数据，管家负责登录和保活。")
                    } actions: {
                        Button("新建 Bot") { showingNewBot = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView("选择一个 Bot", systemImage: "sidebar.left")
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { hub.toggleKeepAlive() } label: {
                    Label(hub.keepAlivePaused ? "开启保活" : "暂停保活",
                          systemImage: hub.keepAlivePaused ? "play.circle.fill" : "pause.circle")
                }
                .labelStyle(.titleAndIcon)
                .help(hub.keepAlivePaused ? "按各 Bot 原来的设置恢复自动保活" : "暂停自动拉起、检查、唤醒和前台轮换，Bot 继续运行")
                Button { hub.startAll() } label: { Label("全部启动", systemImage: "play.fill") }
                    .help("启动所有 Bot 并开启保活")
                    .disabled(hub.bots.isEmpty)
                Button { hub.stopAll() } label: { Label("全部停止", systemImage: "stop.fill") }
                    .help("停止所有 Bot 并关闭保活")
                    .disabled(hub.bots.isEmpty)
                Button { Task { await hub.wakeAll() } } label: { Label("全部唤醒", systemImage: "sun.max") }
                    .help("依次打开每个已登录 Bot 的「电脑」页，休眠的就点一下「唤醒电脑」")
                    .disabled(hub.wakingAll || hub.wakeableBots.isEmpty)
                Button { showingNewBot = true } label: { Label("新建 Bot", systemImage: "plus") }
                    .help("新建一个 Grok Bot 实例并登录")
            }
        }
        .sheet(isPresented: $showingNewBot) {
            NewBotSheet { bot in selection = bot.id }
        }
        .onAppear {
            if selection == nil { selection = hub.bots.first?.id }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(hub.bots) { bot in
                BotSidebarRow(bot: bot).tag(bot.id)
            }
            .onMove { hub.move(from: $0, to: $1) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { HubFooter() }
    }
}

struct BotSidebarRow: View {
    let bot: BotController

    var body: some View {
        let status = BotStatus(bot)
        HStack(spacing: 10) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.profile.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let email = bot.profile.accountEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !bot.profile.keepAlive {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
                    .help("保活已关闭")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct HubFooter: View {
    @Environment(HubController.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Group {
                if hub.keepAlivePaused {
                    Label("全部保活已暂停", systemImage: "pause.circle")
                }
                Label("\(hub.runningCount)/\(hub.bots.count) 个运行中", systemImage: "bolt.horizontal.circle")
                TimelineView(.periodic(from: .now, by: 10)) { _ in
                    Label("\(hub.awakeComputerCount) 台电脑已确认运行", systemImage: "desktopcomputer")
                }
                if let version = hub.grokBotVersion {
                    Label("Grok Bot \(version)", systemImage: "app.badge.checkmark")
                }
                if hub.displayKeptAwake {
                    Label("显示器常亮，Mac 不会自动锁屏", systemImage: "display")
                } else if hub.sleepPrevented {
                    Label("已阻止系统休眠", systemImage: "moon.zzz")
                }
                if hub.keepingComputersAwake {
                    Label("电脑自动检查与恢复已开启", systemImage: "arrow.triangle.2.circlepath")
                }
                if hub.unmanagedInstances > 0 {
                    Label("另有 \(hub.unmanagedInstances) 个非管家实例", systemImage: "questionmark.app")
                        .help("直接打开的 Grok Bot 不在管家的保活范围内")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 10)
    }
}

private struct KeepAlivePausedBanner: View {
    @Environment(HubController.self) private var hub

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("全部保活已暂停").fontWeight(.semibold)
                Text("Bot 继续运行，自动拉起、检查和前台轮换已暂停。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("开启保活") { hub.toggleKeepAlive() }
        }
        .padding(12)
        .background(.bar)
    }
}

private struct MissingGrokBotBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("没有找到 Grok Bot.app").fontWeight(.semibold)
                Text("请先安装 Grok Bot，或在设置里指定它的位置。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link("下载 Grok Bot", destination: GrokBotApp.downloadPage)
            SettingsLink { Text("设置…") }
        }
        .padding(12)
        .background(.orange.opacity(0.1))
    }
}
