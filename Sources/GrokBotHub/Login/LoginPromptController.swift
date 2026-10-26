import AppKit
import AuthenticationServices

/// 登录提示窗口：告诉用户在哪里完成登录，并按 `LoginMode` 打开登录页。
///
/// - 全新会话：ASWebAuthenticationSession（Safari 内核，Google 官方认可的 App 登录方式），临时会话不带任何
///   已有 cookie，所以每个 Bot 都能登不同账号。
/// - 默认浏览器：和 Grok Bot 自带的登录完全一样，沿用浏览器里已有的登录状态。公司单点登录账号在全新会话里
///   可能被公司策略拒绝（如 Google 的 403 app_not_enabled_for_user），用这个方式即可。
///
/// 两种方式下 token 都由 Grok Bot 自己轮询领取；这个窗口开着就表示登录在进行中，被用户关掉即取消。
@MainActor
final class LoginPromptController: NSWindowController, NSWindowDelegate, ASWebAuthenticationPresentationContextProviding {
    var onClose: (() -> Void)?
    var onSwitchToEmbedded: (() -> Void)?

    private let loginURL: URL
    private let botName: String
    private var mode: LoginMode
    private var session: ASWebAuthenticationSession?
    /// 当前会话的令牌；旧会话被取消后的回调是异步到达的，用它过滤掉
    private var sessionToken: UUID?

    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let switchButton = NSButton(title: "", target: nil, action: nil)

    init(botName: String, url: URL) {
        loginURL = url
        self.botName = botName
        mode = HubSettings.loginMode
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "登录 · \(botName)"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        applyModeTexts()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 按当前方式打开（或重新打开）登录页。
    /// - Parameter browserAlreadyOpen: Grok Bot 刚发起登录时自己已经在默认浏览器里打开过，不必再开一个标签页。
    /// - Returns: false 表示全新会话无法启动，调用方应退回内置浏览器。
    @discardableResult
    func start(browserAlreadyOpen: Bool = false) -> Bool {
        endSession()
        switch mode {
        case .browser:
            if !browserAlreadyOpen { NSWorkspace.shared.open(loginURL) }
            HubLog.write("[登录] 在默认浏览器中登录")
            setStatus("已在默认浏览器打开登录页，等待你在浏览器里完成登录…")
            return true
        case .isolated:
            return startIsolatedSession()
        }
    }

    private func startIsolatedSession() -> Bool {
        let token = UUID()
        sessionToken = token
        // 登录完成页如果跳转 grokbot://，在这里截下并丢弃，不让系统把它转给某个实例
        let session = ASWebAuthenticationSession(url: loginURL, callbackURLScheme: "grokbot") { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.sessionToken == token else { return }
                    self.sessionEnded(callbackURL: callbackURL, error: error)
                }
            }
        }
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        self.session = session
        let started = session.start()
        HubLog.write(started ? "[登录] 已打开全新会话的安全登录窗口" : "[登录] 安全登录窗口无法启动")
        setStatus(started ? "正在等待你在安全登录窗口中完成登录…" : "安全登录窗口无法打开。")
        return started
    }

    /// 取消当前会话；之后到达的回调会因令牌不匹配被忽略。
    private func endSession() {
        sessionToken = nil
        session?.cancel()
        session = nil
    }

    private func sessionEnded(callbackURL: URL?, error: Error?) {
        sessionToken = nil
        session = nil
        if callbackURL != nil {
            HubLog.write("[登录] 网页端已完成登录确认")
            setStatus("网页端已完成，正在等待 Grok Bot 确认登录…")
        } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
            setStatus("安全登录窗口已关闭。可以点「重新打开」再试，或改用默认浏览器。")
        } else {
            HubLog.write("[登录] 安全登录窗口出错：\(error?.localizedDescription ?? "未知")")
            setStatus("安全登录窗口出错：\(error?.localizedDescription ?? "未知错误")。可以改用默认浏览器。")
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        fitWindowToContent()
    }

    /// 文案长短随登录方式和状态变化，窗口高度跟着内容走。
    private func fitWindowToContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.height > 0, abs(size.height - content.frame.height) > 1 else { return }
        var frame = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: content.frame.width, height: size.height)))
        frame.origin.y += frame.height - newFrame.height   // 保持窗口顶边不动
        frame.size.height = newFrame.height
        window.setFrame(frame, display: true)
    }

    private func applyModeTexts() {
        switch mode {
        case .isolated:
            detailLabel.stringValue = """
            在弹出的安全登录窗口里登录这个 Bot 要用的账号（支持 Google），然后在页面上确认。这是全新会话，不会带入其他账号。
            公司账号（单点登录）如果在这里报错，点「改用默认浏览器」，按 Grok Bot 自带的方式登录。
            """
            switchButton.title = "改用默认浏览器"
        case .browser:
            detailLabel.stringValue = """
            登录页已在默认浏览器打开，和 Grok Bot 自带的登录完全一样。在浏览器里完成登录并确认即可，本窗口请保持打开，登录成功后会自动关闭。
            如果浏览器里已经登着别的 Grok 账号，请先在网页上切换到「\(botName)」要用的账号。
            """
            switchButton.title = "改用全新会话"
        }
        fitWindowToContent()
    }

    // MARK: 界面

    private func makeContent() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "为「\(botName)」登录 Grok Bot 账号")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        // 换行标签要有确定的宽度，fittingSize 才能算出正确的高度
        detailLabel.preferredMaxLayoutWidth = 450
        statusLabel.preferredMaxLayoutWidth = 450

        let reopen = NSButton(title: "重新打开", target: self, action: #selector(reopen))
        switchButton.target = self
        switchButton.action = #selector(switchMode)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelLogin))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [reopen, switchButton, NSView(), cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let texts = NSStackView(views: [title, detailLabel, statusLabel, buttons])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 10
        texts.setCustomSpacing(16, after: statusLabel)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [icon, texts])
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 20, right: 22)
        NSLayoutConstraint.activate([
            buttons.widthAnchor.constraint(equalTo: texts.widthAnchor),
            texts.widthAnchor.constraint(equalToConstant: 450),
        ])
        return root
    }

    @objc private func reopen() {
        start()
    }

    /// 切换登录方式，并记住这次的选择（设置里也能改）。
    @objc private func switchMode() {
        mode = mode == .isolated ? .browser : .isolated
        HubSettings.loginMode = mode
        applyModeTexts()
        if !start(), mode == .isolated {
            onSwitchToEmbedded?()
        }
    }

    @objc private func cancelLogin() {
        close()
    }

    // MARK: NSWindowDelegate

    /// 关窗口时一并收起安全登录窗口。是不是「用户取消」由 LoginWindowManager 判断：
    /// 管家主动关闭时会先把它从列表里移除。
    func windowWillClose(_ notification: Notification) {
        endSession()
        onClose?()
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? NSWindow() }
    }
}
