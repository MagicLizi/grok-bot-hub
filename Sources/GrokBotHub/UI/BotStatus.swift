import SwiftUI

/// 把 Bot 的运行时状态归纳成一句话 + 一个色调，侧边栏、详情页和菜单栏共用。
struct BotStatus {
    enum Tone { case good, busy, bad, idle }

    let text: String
    let tone: Tone

    var color: Color {
        switch tone {
        case .good: return .green
        case .busy: return .orange
        case .bad: return .red
        case .idle: return .secondary
        }
    }

    @MainActor
    init(_ bot: BotController) {
        switch bot.phase {
        case .stopped:
            self.init(text: "已停止", tone: .idle)
        case .stopping:
            self.init(text: "正在停止", tone: .busy)
        case .launching:
            self.init(text: "正在启动", tone: .busy)
        case .waitingRestart:
            self.init(text: "等待自动拉起", tone: .bad)
        case .running:
            if bot.loginActive {
                self.init(text: "登录中", tone: .busy)
            } else if bot.keepAlivePaused {
                self.init(text: "运行中（保活已暂停）", tone: .idle)
            } else if case .unresponsive = bot.health {
                self.init(text: "无响应", tone: .bad)
            } else if bot.health == .noDebugPort {
                self.init(text: "运行中（未接管）", tone: .busy)
            } else if bot.auth == .loggedOut {
                self.init(text: "未登录", tone: .bad)
            } else if bot.auth == .loggingIn {
                self.init(text: "等待完成登录", tone: .busy)
            } else if bot.auth == .loggedIn {
                if bot.keepsComputerAwake {
                    self.init(computer: bot)
                } else {
                    self.init(text: bot.health == .windowClosed ? "已登录（窗口已关闭）" : "已登录", tone: .good)
                }
            } else {
                self.init(text: "正在连接", tone: .busy)
            }
        }
    }

    @MainActor
    init(computer bot: BotController) {
        if bot.keepAlivePaused, !bot.wakeActive {
            self.init(text: "保活已暂停", tone: .idle)
            return
        }
        guard bot.isRunning else {
            self.init(text: "未运行", tone: .idle)
            return
        }
        guard bot.auth == .loggedIn else {
            self.init(text: "等待登录后检查", tone: .busy)
            return
        }
        if bot.wakeActive {
            self.init(text: "正在检查并恢复电脑", tone: .busy)
        } else if bot.computerIssue != nil {
            self.init(text: "电脑需要处理", tone: .bad)
        } else if bot.computerConfirmedAwake {
            self.init(text: bot.computerState == .onDevice ? "在此设备上运行" : "电脑运行中", tone: .good)
        } else {
            switch bot.computerState {
            case .asleep: self.init(text: "电脑正在休眠", tone: .bad)
            case .waking: self.init(text: "电脑正在启动", tone: .busy)
            case .unreachable: self.init(text: "电脑连接异常", tone: .bad)
            case .away: self.init(text: "电脑屏幕已暂停", tone: .busy)
            case .paused: self.init(text: "电脑暂不可用", tone: .bad)
            case .notShown, .unrecognizedFullscreen: self.init(text: "未识别到电脑状态", tone: .busy)
            case .awake, .onDevice, .none:
                self.init(text: bot.keepsComputerAwake ? "等待检查电脑" : "自动检查已关闭", tone: .idle)
            }
        }
    }

    private init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

struct StatusDot: View {
    let status: BotStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(status.text)
    }
}

struct StatusPill: View {
    let status: BotStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status)
            Text(status.text)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.12), in: Capsule())
    }
}
