import Foundation

/// `<user-data-dir>/DevToolsActivePort` 的内容：第一行端口，第二行 browser websocket 路径。
public struct DevToolsActivePort: Equatable {
    public let port: Int
    public let browserPath: String

    public init?(contents: String) {
        let lines = contents.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, let port = Int(first), (1...65535).contains(port) else { return nil }
        self.port = port
        self.browserPath = lines.count > 1 ? lines[1] : ""
    }
}

/// `/json/list` 中的一个调试目标。
public struct DevToolsTarget: Equatable {
    public let id: String
    public let type: String
    public let title: String
    public let url: String
    public let webSocketDebuggerURL: URL

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let type = json["type"] as? String,
              let ws = (json["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
        self.id = id
        self.type = type
        self.title = json["title"] as? String ?? ""
        self.url = json["url"] as? String ?? ""
        self.webSocketDebuggerURL = ws
    }

    /// Grok Bot 主窗口加载的是 app.asar 里的 `dist/renderer/index.html`。
    public var isGrokBotMainWindow: Bool {
        type == "page" && url.contains("/dist/renderer/index.html")
    }

    public static func mainWindow(in targets: [DevToolsTarget]) -> DevToolsTarget? {
        targets.first(where: \.isGrokBotMainWindow)
    }
}
