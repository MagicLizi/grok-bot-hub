import AppKit
import HubCore
import WebKit

/// 每个 Bot 最多一个登录窗口。
///
/// 默认弹登录提示窗口（全新会话或默认浏览器，见 LoginPromptController）；全新会话打不开时改用内置浏览器窗口。
/// 窗口被用户关掉 = 取消这次登录；管家主动关闭时会先把它移出列表，不算取消。
@MainActor
final class LoginWindowManager {
    private var windows: [String: NSWindowController] = [:]

    /// - Parameter browserAlreadyOpen: Grok Bot 刚在默认浏览器里打开过登录页。
    func open(for bot: BotController, url: URL, browserAlreadyOpen: Bool) {
        let id = bot.id
        let name = bot.profile.name
        let storeID = bot.profile.webStoreID
        if let existing = windows[id] {
            if let prompt = existing as? LoginPromptController {
                prompt.start()
            } else if let embedded = existing as? LoginWindowController {
                embedded.load(url)
            }
            focus(id)
            return
        }

        let prompt = LoginPromptController(botName: name, url: url)
        prompt.onClose = { [weak self, weak prompt] in self?.forget(id, prompt) }
        prompt.onSwitchToEmbedded = { [weak self, weak prompt] in
            self?.openEmbedded(id: id, name: name, storeID: storeID, url: url, replacing: prompt)
        }
        windows[id] = prompt
        present(prompt)
        if !prompt.start(browserAlreadyOpen: browserAlreadyOpen) {
            openEmbedded(id: id, name: name, storeID: storeID, url: url, replacing: prompt)
        }
    }

    private func openEmbedded(id: String, name: String, storeID: UUID, url: URL, replacing old: NSWindowController?) {
        let embedded = LoginWindowController(botName: name, storeID: storeID, url: url)
        embedded.onClose = { [weak self, weak embedded] in self?.forget(id, embedded) }
        windows[id] = embedded   // 先替换，旧窗口关闭时就不会被当成取消
        old?.close()
        present(embedded)
        HubLog.write("[登录] 改用内置浏览器窗口")
    }

    private func present(_ controller: NSWindowController) {
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate()
    }

    private func forget(_ id: String, _ controller: NSWindowController?) {
        if let controller, windows[id] === controller {
            windows[id] = nil
        }
    }

    func isOpen(_ id: String) -> Bool { windows[id] != nil }

    func focus(_ id: String) {
        windows[id]?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(for id: String) {
        windows.removeValue(forKey: id)?.close()
    }

    #if DEBUG
    /// 自测用：把所有窗口和登录页内容存成 PNG（没有截屏权限时用来检查界面）。
    func debugSnapshots(into dir: URL) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window-\(index).png"))
        }
        for (id, controller) in windows {
            (controller as? LoginWindowController)?.debugSnapshot(to: dir.appendingPathComponent("login-\(id).png"))
        }
    }
    #endif
}

/// 内置浏览器登录窗口（备用方案）。
///
/// 每个 Bot 使用自己的 WKWebsiteDataStore，cookie 互不相通，所以可以给不同 Bot 登录不同账号，
/// 也不会动系统浏览器里的登录状态。Google 可能拒绝在内嵌 WebView 里登录，所以默认走 LoginPromptController。
@MainActor
final class LoginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    /// 部分登录页会拒绝内嵌 WebView 的默认 UA，伪装成 Safari
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    var onClose: (() -> Void)?

    private let webView: WKWebView
    private let loginURL: URL
    private var popups: [NSWindow] = []

    init(botName: String, storeID: UUID, url: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        loginURL = url

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "登录 · \(botName)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 520)
        super.init(window: window)

        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView = makeContent(botName: botName)
        load(url)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    private func makeContent(botName: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "为「\(botName)」登录 Grok Bot 账号")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString:
            "在下方登录这个 Bot 要用的账号，并在页面上确认登录。如果 Google 提示「浏览器不安全」，请关掉本窗口重新点「登录」，使用安全登录窗口。登录成功后本窗口会自动关闭。")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor

        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let reload = NSButton(title: "重新打开登录页", target: self, action: #selector(reloadLogin))
        let copy = NSButton(title: "复制链接", target: self, action: #selector(copyLink))
        for button in [reload, copy] { button.bezelStyle = .rounded; button.controlSize = .small }

        let header = NSStackView(views: [icon, texts, reload, copy])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let divider = NSBox()
        divider.boxType = .separator

        let root = NSStackView(views: [header, divider, webView])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .width
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return root
    }

    @objc private func reloadLogin() { load(loginURL) }

    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(loginURL.absoluteString, forType: .string)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        popups.forEach { $0.close() }
        popups.removeAll()
        webView.stopLoading()
        onClose?()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        // grokbot:// 之类的回调交给系统会被路由到任意一个 Grok Bot 实例；token 本来就走轮询，直接丢弃
        if LoginLink.isAppCallbackScheme(scheme) {
            decisionHandler(.cancel)
            return
        }
        if let scheme, !["http", "https", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// 只记域名、路径和标题，不记查询参数（里面有登录 challenge）。
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url
        HubLog.write("[登录窗口] 已加载 \(url?.host ?? "")\(url?.path ?? "")「\(webView.title ?? "")」")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        HubLog.write("[登录窗口] 加载失败：\(error.localizedDescription)")
    }

    #if DEBUG
    func debugSnapshot(to url: URL) {
        webView.takeSnapshot(with: nil) { image, _ in
            guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }
    #endif

    // MARK: WKUIDelegate

    /// OAuth（Google / GitHub 等）可能用弹窗，给它一个共享会话的子窗口。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popupView = WKWebView(frame: .zero, configuration: configuration)
        popupView.customUserAgent = Self.userAgent
        popupView.navigationDelegate = self
        popupView.uiDelegate = self
        let popup = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        popup.isReleasedWhenClosed = false
        popup.title = window?.title ?? "登录"
        popup.contentView = popupView
        popup.center()
        popup.makeKeyAndOrderFront(nil)
        popups.append(popup)
        return popupView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let popup = popups.first(where: { $0.contentView === webView }) else { return }
        popup.close()
        popups.removeAll { $0 === popup }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}
