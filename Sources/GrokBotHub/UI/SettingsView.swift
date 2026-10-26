import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(HubController.self) private var hub
    @AppStorage(SettingKey.preventSleep) private var preventSleep = true
    @AppStorage(SettingKey.keepDisplayAwake) private var keepDisplayAwake = true
    @AppStorage(SettingKey.keepComputersAwake) private var keepComputersAwake = true
    @AppStorage(SettingKey.restartUnresponsive) private var restartUnresponsive = true
    @AppStorage(SettingKey.disableGrokBotAppNap) private var disableAppNap = true
    @AppStorage(SettingKey.grokBotAppPath) private var grokBotAppPath = ""
    @AppStorage(SettingKey.loginMode) private var loginMode = LoginMode.isolated.rawValue
    @ViewState private var launchAtLogin = false
    @ViewState private var choosingApp = false

    var body: some View {
        Form {
            Section("登录") {
                Picker("登录方式", selection: $loginMode) {
                    Text("全新会话").tag(LoginMode.isolated.rawValue)
                    Text("默认浏览器").tag(LoginMode.browser.rawValue)
                }
                Text(loginMode == LoginMode.browser.rawValue
                     ? "和 Grok Bot 自带的登录完全一样，沿用浏览器里已有的登录状态，适合公司单点登录账号。给不同 Bot 登不同账号时，需要先在网页上切换账号。"
                     : "每次都是不带任何登录状态的安全登录窗口，适合给每个 Bot 登不同的个人账号。公司单点登录账号可能会被拒绝，这时改用默认浏览器。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("保活") {
                Toggle("自动保持所有 Bot 的电脑运行", isOn: $keepComputersAwake)
                Text("每 30 秒检查已登录且开启保活的 Bot，休眠时自动唤醒，屏幕暂停或连接失败时自动恢复。每 3 分钟轮流把 Bot 窗口带到前台，停留 3 秒后切回原窗口。新加入并登录的 Bot 自动纳入；停止 Bot 或关闭保活会取消它的自动操作。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Mac 锁屏、账号退出或服务端暂停时会显示原因，条件恢复后继续检查。电脑是否运行以详情页最近一次确认的状态为准。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("有 Bot 运行时保持显示器常亮，防止 Mac 锁屏", isOn: $keepDisplayAwake)
                Text("Mac 锁屏后 Grok Bot 认为没人在电脑前，不会唤醒云端电脑。锁屏由显示器关闭或屏保触发，显示器常亮就不会自动锁屏，也不会休眠。手动锁屏、手动睡眠不受影响。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("有 Bot 运行时阻止系统闲置休眠", isOn: $preventSleep)
                    .disabled(keepDisplayAwake)
                Text("只阻止休眠，显示器仍会按系统设置关闭，之后可能锁屏。开启上一项时已包含这一项。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("无响应时自动重启", isOn: $restartUnresponsive)
                Text("连续约 2 分钟检测不到响应时，强制结束并重新拉起（只对开启保活的 Bot 生效）。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("阻止 Grok Bot 进入 App Nap", isOn: $disableAppNap)
                Text("后台时不被系统节流。对所有 Grok Bot 实例生效，实例重启后起作用。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("启动") {
                Toggle("登录 macOS 时自动打开管家", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        hub.launchAtLogin = on
                        launchAtLogin = hub.launchAtLogin
                    }
                Text("管家启动后会自动拉起所有开启了保活的 Bot。退出管家不会关闭 Bot，但保活会暂停。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Grok Bot") {
                LabeledContent("位置") {
                    Text(hub.grokBotURL?.path ?? "未找到")
                        .foregroundStyle(hub.grokBotURL == nil ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("版本", value: hub.grokBotVersion ?? "—")
                HStack {
                    Button("选择…") { choosingApp = true }
                    if !grokBotAppPath.isEmpty {
                        Button("恢复自动查找") {
                            grokBotAppPath = ""
                            hub.applySettings()
                        }
                    }
                    Spacer()
                    Link("下载 Grok Bot", destination: GrokBotApp.downloadPage)
                }
            }

            Section("数据") {
                HStack {
                    Button("打开 Bot 数据目录") { NSWorkspace.shared.open(HubPaths.profilesDir) }
                    Button("打开日志") {
                        NSWorkspace.shared.activateFileViewerSelecting([HubPaths.logFile])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
        .onAppear { launchAtLogin = hub.launchAtLogin }
        .onChange(of: preventSleep) { hub.applySettings() }
        .onChange(of: keepDisplayAwake) { hub.applySettings() }
        .onChange(of: keepComputersAwake) { hub.applySettings() }
        .onChange(of: disableAppNap) { hub.applySettings() }
        .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.application]) { result in
            if case .success(let url) = result {
                grokBotAppPath = url.path
                hub.applySettings()
            }
        }
    }
}
