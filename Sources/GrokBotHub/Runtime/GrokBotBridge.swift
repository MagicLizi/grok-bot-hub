import Foundation
import HubCore

/// 通过 CDP 调用 Grok Bot 渲染进程里 preload 暴露的 `window.desktop.main.*` 接口。
/// 这些就是 Grok Bot 自己界面上「登录 / 复制登录链接 / 退出登录」按钮调用的同一组方法。
struct GrokBotBridge {
    let client: DevToolsClient

    private func run(_ expression: String, timeout: TimeInterval = 10) async throws -> Any? {
        let target = try await client.mainWindow()
        return try await client.evaluate(expression, in: target, timeout: timeout)
    }

    /// 调用 `window.desktop.main.<method>()`，结果先在页面里 JSON 化再取回。
    private func callMain(_ method: String, timeout: TimeInterval = 10) async throws -> Any? {
        let js = "window.desktop.main.\(method)().then(v => JSON.stringify(v === undefined ? null : v))"
        guard let text = try await run(js, timeout: timeout) as? String else { throw DevToolsError.badResponse }
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    func ping() async throws {
        _ = try await run("1", timeout: 8)
    }

    func isReady() async throws -> Bool {
        try await run("typeof window.desktop?.main?.getCursorAuthStatus === 'function'") as? Bool ?? false
    }

    func authStatus() async throws -> GrokBotAuthStatus {
        guard let json = try await callMain("getCursorAuthStatus") as? [String: Any],
              let status = GrokBotAuthStatus(json: json) else { throw DevToolsError.badResponse }
        return status
    }

    func loginFlight() async throws -> GrokBotLoginFlight {
        GrokBotLoginFlight(json: try await callMain("getCursorLoginFlight") as? [String: Any] ?? [:])
    }

    /// 等同于点 Grok Bot 欢迎页的「Sign in」。`loginCursor()` 要等登录结束才返回，这里不等它。
    func startLogin() async throws {
        _ = try await run("(window.__grokBotHubLogin = window.desktop.main.loginCursor().catch(e => ({ error: String(e) })), true)")
    }

    /// Grok Bot 把当前登录链接写进剪贴板，返回 "copied" / "idle" / "finishing"。
    func copyLoginLink() async throws -> String? {
        try await callMain("copyCursorLoginLink") as? String
    }

    func cancelLogin() async throws {
        _ = try await callMain("cancelCursorLoginFlight")
    }

    func logout() async throws {
        _ = try await callMain("logoutCursor", timeout: 15)
    }

    /// 「电脑」的状态。电脑页里是小预览卡片；电脑被放大成全屏画面时预览卡片不渲染，改看全屏画面。
    /// 文案取自 Grok Bot 0.75 的界面（简体 / 繁体 / 英文），按钮按 class 和文案识别。
    typealias ComputerState = HubCore.ComputerState

    private static let computerStateJS = """
    const T = {
      waking: /正在唤醒|正在喚醒|Waking up|正在设置|正在設定|Setting up|正在启动桌面|正在啟動桌面|Starting desktop|正在切换到|正在切換到|Switching to|连接中|連結中|Connecting/i,
      wake: /唤醒|喚醒|wake/i,
      asleep: /电脑正在休眠|電腦正在休眠|Computer is asleep/i,
      away: /屏幕已暂停|螢幕已暫停|Screen paused/i,
      unreachable: /无法连接|無法連上|無法連接|can.?t reach|couldn.?t reach|can.?t connect|couldn.?t connect/i,
      paused: /电脑正在重建|電腦正在重建|being rebuilt|电脑已暂时暂停|電腦已暫時暫停|computer is temporarily paused/i,
      onDevice: /在此设备上运行|在此裝置上執行|Works on this device/i,
      control: /仅观看|僅觀看|Watching|取得控制权|取得控制權|Take control|你正在控制|You.re in control/i,
      retry: /^(重试|重試|再試一次|Retry|Try again)$/i,
    };
    const preview = document.querySelector('.sand-computer-preview');
    const fullscreen = preview ? null : document.querySelector('.sand-computer-fullscreen');
    const scope = preview || fullscreen;
    const text = scope ? (scope.innerText || '') : '';
    const labelOf = el => [el.getAttribute('aria-label'), el.innerText, el.title].filter(Boolean).join(' ');
    const buttons = scope ? [...scope.querySelectorAll('button, [role=button]')] : [];
    const openBtn = fullscreen ? null : document.querySelector('.sand-computer-preview__open');
    const wakeBtn = openBtn ? (T.wake.test(labelOf(openBtn)) ? openBtn : null)
      : buttons.find(b => T.wake.test(labelOf(b))) || null;
    const retryBtn = buttons.find(b => T.retry.test((b.innerText || b.getAttribute('aria-label') || '').trim())) || null;
    const isDisabled = b => !!b && (b.disabled || b.getAttribute('aria-disabled') === 'true');
    const state = (() => {
      if (!scope && !openBtn) return T.paused.test(document.body ? document.body.innerText : '') ? 'paused' : 'notShown';
      if (T.paused.test(text)) return 'paused';
      if (isDisabled(wakeBtn) || T.waking.test(text)) return 'waking';
      if (wakeBtn || T.asleep.test(text)) return 'asleep';
      if (T.away.test(text)) return 'away';
      if (T.unreachable.test(text)) return 'unreachable';
      if (T.onDevice.test(text)) return 'onDevice';
      if (fullscreen) return fullscreen.querySelector('.sand-computer-control-bar') || T.control.test(text) ? 'awake' : 'unrecognizedFullscreen';
      return openBtn ? 'awake' : 'notShown';
    })();
    """

    func computerState() async throws -> ComputerState {
        let js = "(() => { \(Self.computerStateJS)\n return state; })()"
        guard let raw = try await run(js) as? String, let state = ComputerState(rawValue: raw) else {
            throw DevToolsError.badResponse
        }
        return state
    }

    /// 电脑睡着时点一次「唤醒电脑」；其他状态什么都不做，返回 false。
    func clickWakeComputer() async throws -> Bool {
        try await clickIf("state === 'asleep' && wakeBtn ? wakeBtn : null")
    }

    /// 点一次电脑页或全屏画面里的「重试」；没有时返回 false。
    func clickRetry() async throws -> Bool {
        try await clickIf("retryBtn")
    }

    /// 点全屏电脑画面右上角的「退出全屏」，回到带预览卡片的电脑页；不在全屏时返回 false。
    func exitComputerFullscreen() async throws -> Bool {
        try await clickIf("fullscreen && [...fullscreen.querySelectorAll('button')].find(b => /退出全屏|離開全螢幕|退出全螢幕|exit full ?screen/i.test(labelOf(b)))")
    }

    private func clickIf(_ target: String) async throws -> Bool {
        let js = """
        (() => {
          \(Self.computerStateJS)
          const target = \(target);
          if (!target || isDisabled(target)) return false;
          target.click();
          return true;
        })()
        """
        return try await run(js) as? Bool ?? false
    }

    /// 在窗口标题后面挂上 Bot 名字，方便在调度中心 / 窗口菜单里区分多个实例。
    func tagWindowTitle(_ name: String) async throws {
        let literal = String(decoding: try JSONEncoder().encode(" — " + name), as: UTF8.self)
        let js = """
        (() => {
          window.__grokBotHubTitleTag = \(literal);
          const apply = () => {
            const tag = window.__grokBotHubTitleTag;
            if (document.title.endsWith(tag)) return;
            let base = document.title;
            const prev = window.__grokBotHubAppliedTag;
            if (prev && base.endsWith(prev)) base = base.slice(0, -prev.length);
            window.__grokBotHubAppliedTag = tag;
            document.title = base + tag;
          };
          if (!window.__grokBotHubTitleObserver) {
            window.__grokBotHubTitleObserver = new MutationObserver(apply);
            window.__grokBotHubTitleObserver.observe(document.head, { subtree: true, childList: true, characterData: true });
          }
          apply();
          return true;
        })()
        """
        _ = try await run(js)
    }
}
