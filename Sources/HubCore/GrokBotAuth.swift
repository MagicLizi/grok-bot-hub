import Foundation

/// `window.desktop.main.getCursorAuthStatus()` 的返回值。
/// 实测形如 `{"kind":"logged-in","authId":"…","email":"…","displayName":"…"}`，
/// 未登录为 `{"kind":"logged-out"}`，登录进行中为 `{"kind":"logging-in"}`。
public struct GrokBotAuthStatus: Equatable {
    public enum Kind: Equatable {
        case loggedIn, loggedOut, loggingIn, other(String)
    }

    public let kind: Kind
    public let email: String?
    public let displayName: String?

    public init(kind: Kind, email: String? = nil, displayName: String? = nil) {
        self.kind = kind
        self.email = email
        self.displayName = displayName
    }

    public init?(json: [String: Any]) {
        guard let raw = json["kind"] as? String else { return nil }
        switch raw {
        case "logged-in": kind = .loggedIn
        case "logged-out": kind = .loggedOut
        case "logging-in": kind = .loggingIn
        default: kind = .other(raw)
        }
        email = (json["email"] as? String)?.nilIfEmpty
        displayName = (json["displayName"] as? String)?.nilIfEmpty
    }
}

/// `getCursorLoginFlight()` 的返回值：`{"kind":"idle"}` 或 `{"kind":"waiting-for-browser",...}`。
public enum GrokBotLoginFlight: Equatable {
    case idle, waitingForBrowser, other(String)

    public init(json: [String: Any]) {
        switch json["kind"] as? String {
        case "idle": self = .idle
        case "waiting-for-browser": self = .waitingForBrowser
        case let other: self = .other(other ?? "unknown")
        }
    }
}

public enum LoginLink {
    /// 只接受 Cursor 官方的 loginDeepControl 链接，避免把剪贴板里的任意内容当成登录页打开。
    public static func validate(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "cursor.com" || host.hasSuffix(".cursor.com"),
              url.path == "/loginDeepControl" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = Set(items.map(\.name))
        guard names.contains("challenge"), names.contains("uuid") else { return nil }
        return url
    }

    /// 登录窗口里拦截的 scheme：这些回调若交给系统，会被路由到任意一个 Grok Bot 实例。
    public static func isAppCallbackScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return ["grokbot", "sand", "cursor"].contains(scheme)
    }
}
