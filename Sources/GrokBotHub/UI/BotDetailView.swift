import SwiftUI

struct BotDetailView: View {
    @Environment(HubController.self) private var hub
    let bot: BotController

    @ViewState private var renaming = false
    @ViewState private var newName = ""
    @ViewState private var confirmingDelete = false
    @ViewState private var deleting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                facts
                computer
                eventLog
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(bot.profile.name)
        .alert("重命名", isPresented: $renaming) {
            TextField("名字", text: $newName)
            Button("保存") { bot.rename(newName) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除「\(bot.profile.name)」？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                deleting = true
                Task { await hub.delete(bot) }
            }
        } message: {
            Text("会退出这个实例的登录、关掉进程，并把它的本地数据目录移到废纸篓。云端的 Bot 和任务不受影响。")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 26, weight: .light))
                .frame(width: 52, height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(bot.profile.name)
                        .font(.title2.weight(.semibold))
                    Button {
                        newName = bot.profile.name
                        renaming = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("重命名")
                }
                accountLine
            }
            Spacer()
            StatusPill(status: BotStatus(bot))
        }
    }

    @ViewBuilder
    private var accountLine: some View {
        if let email = bot.profile.accountEmail {
            Label(bot.profile.accountName.map { "\($0) · \(email)" } ?? email, systemImage: "person.crop.circle")
                .foregroundStyle(.secondary)
        } else {
            Label("尚未登录 Grok Bot 账号", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                bot.beginLogin()
            } label: {
                Label(bot.loginActive ? "登录进行中…" : (bot.auth == .loggedIn ? "检查登录" : "登录"),
                      systemImage: "person.badge.key")
            }
            .buttonStyle(.borderedProminent)
            .disabled(hub.grokBotURL == nil)

            Button { bot.showWindow() } label: { Label("显示窗口", systemImage: "macwindow") }

            Button {
                Task { await bot.wakeComputer() }
            } label: {
                Label(bot.wakeActive ? "唤醒中…" : "唤醒电脑", systemImage: "sun.max")
            }
            .help("打开这个 Bot 的「电脑」页，电脑在休眠就点一下「唤醒电脑」")
            .disabled(hub.grokBotURL == nil || bot.wakeActive || (bot.auth != .loggedIn && bot.profile.accountEmail == nil))

            if bot.isRunning {
                Button { bot.restart() } label: { Label("重启", systemImage: "arrow.clockwise") }
                Button { bot.stop() } label: { Label("停止", systemImage: "stop.fill") }
            } else {
                Button { bot.start() } label: { Label("启动", systemImage: "play.fill") }
                    .disabled(hub.grokBotURL == nil)
            }

            Menu {
                Button("退出登录") { bot.logout() }
                    .disabled(bot.auth != .loggedIn)
                Button("在 Finder 中显示数据目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([bot.profile.dataDir])
                }
                Divider()
                Button("删除 Bot…", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.large)
        .disabled(deleting)
    }

    private var facts: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    label("保活")
                    Toggle(isOn: Binding(get: { bot.profile.keepAlive }, set: { bot.setKeepAlive($0) })) {
                        Text(bot.profile.keepAlive ? "开启：退出、崩溃或卡死都会被自动拉起" : "关闭：退出后不再自动拉起")
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                GridRow {
                    label("进程")
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(processText(now: context.date))
                    }
                }
                GridRow {
                    label("连接")
                    Text(healthText)
                }
                GridRow {
                    label("自动拉起")
                    Text(bot.autoRestarts == 0 ? "本次运行管家期间没有发生" : "\(bot.autoRestarts) 次")
                }
                if let last = bot.profile.lastLoginAt {
                    GridRow {
                        label("最近登录")
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                GridRow {
                    label("数据目录")
                    Text(bot.profile.dataDir.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("事件").font(.headline)
            if bot.events.isEmpty {
                Text("暂无事件").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bot.events.prefix(60)) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(event.date.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: icon(for: event.level))
                                .font(.caption)
                                .foregroundStyle(color(for: event.level))
                            Text(event.message)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var computer: some View {
        GroupBox("电脑") {
            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    StatusPill(status: BotStatus(computer: bot))
                }
                Text(bot.keepsComputerAwake
                     ? "自动检查已开启 · 每 30 秒检查，每 3 分钟轮换前台"
                     : "自动检查已关闭，可手动唤醒电脑")
                    .font(.callout).foregroundStyle(.secondary)
                if let issue = bot.computerIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let checkedAt = bot.computerCheckedAt {
                    LabeledContent("最近检查", value: checkedAt.formatted(date: .omitted, time: .standard))
                }
                if let activatedAt = bot.lastComputerActivationAt {
                    LabeledContent("最近前台轮换", value: activatedAt.formatted(date: .omitted, time: .standard))
                }
                if let retryAt = bot.computerRetryAt, bot.keepsComputerAwake {
                    LabeledContent("下次恢复尝试", value: retryAt.formatted(date: .omitted, time: .standard))
                }
                if bot.autoComputerRecoveries > 0 {
                    LabeledContent("自动恢复成功", value: "\(bot.autoComputerRecoveries) 次")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func processText(now: Date) -> String {
        switch bot.phase {
        case .running:
            let uptime = bot.runningSince.map { BotController.describe(now.timeIntervalSince($0)) } ?? "—"
            return "pid \(bot.pid.map(String.init) ?? "—") · 已运行 \(uptime)"
        case .waitingRestart(let at):
            return "已退出，\(BotController.describe(at.timeIntervalSince(now))) 后自动拉起"
        case .launching: return "正在启动"
        case .stopping: return "正在停止"
        case .stopped: return "未运行"
        }
    }

    private var healthText: String {
        switch bot.health {
        case .unknown: return "—"
        case .connecting: return "正在连接调试端口"
        case .ok: return "正常"
        case .windowClosed: return "正常（主窗口已关闭，点「显示窗口」可重新打开）"
        case .noDebugPort: return "未接管：这个实例不是管家启动的，点「重启」后接管"
        case .unresponsive(let n): return "无响应（连续 \(n) 次检查失败）"
        }
    }

    private func icon(for level: BotController.Event.Level) -> String {
        switch level {
        case .info: return "circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for level: BotController.Event.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
