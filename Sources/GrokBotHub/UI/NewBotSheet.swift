import SwiftUI

struct NewBotSheet: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismiss) private var dismiss
    var onCreated: (BotController) -> Void

    @AppStorage(SettingKey.loginMode) private var loginMode = LoginMode.isolated.rawValue
    @ViewState private var name = ""
    @ViewState private var loginNow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建 Bot").font(.title3.weight(.semibold))
            Text("管家会为它准备独立的数据目录，启动一个新的 Grok Bot 实例，并接管登录和保活。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("名字", text: $name, prompt: Text(hub.suggestedName()))
                Toggle("创建后立即登录", isOn: $loginNow)
            }
            .formStyle(.columns)

            if loginNow {
                Label(loginMode == LoginMode.browser.rawValue
                      ? "会在默认浏览器里打开登录页，和 Grok Bot 自带的登录一样。如果浏览器里登着别的账号，记得先在网页上切换。"
                      : "会弹出全新会话的安全登录窗口（支持 Google），可以给每个 Bot 登不同账号。公司账号如果报错，在登录窗口里改用默认浏览器。",
                      systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    let bot = hub.createBot(name: name, loginNow: loginNow)
                    onCreated(bot)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hub.grokBotURL == nil)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
