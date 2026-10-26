import Foundation
import HubCore

enum DevToolsError: LocalizedError {
    case noPortFile
    case wrongProcess
    case http(String)
    case noMainWindow
    case timeout
    case evaluation(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noPortFile: return "调试端口文件还没生成"
        case .wrongProcess: return "调试端口不属于这个实例"
        case .http(let m): return "调试端口无法访问：\(m)"
        case .noMainWindow: return "Grok Bot 主窗口不存在"
        case .timeout: return "调用超时"
        case .evaluation(let m): return "页面脚本出错：\(m)"
        case .badResponse: return "调试协议返回了无法识别的数据"
        }
    }
}

/// 极简 Chrome DevTools Protocol 客户端：HTTP 列目标 + 一次性 WebSocket 调用。
struct DevToolsClient {
    let port: Int

    /// 读取 `<user-data-dir>/DevToolsActivePort`，并确认端口背后的浏览器进程就是 `expectedPID`。
    /// 文件可能是上一次运行留下的，端口也可能已被别的实例占用，所以必须校验 PID。
    static func discover(userDataDir: URL, expectedPID: pid_t) async throws -> DevToolsClient {
        let file = userDataDir.appendingPathComponent("DevToolsActivePort")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let parsed = DevToolsActivePort(contents: text) else { throw DevToolsError.noPortFile }
        let client = DevToolsClient(port: parsed.port)
        guard try await client.browserPID() == expectedPID else { throw DevToolsError.wrongProcess }
        return client
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.connectionProxyDictionary = [:]   // 本机端口不走系统代理（比如 Surge）
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func browserWebSocketURL() async throws -> URL {
        guard let version = try await getJSON("/json/version") as? [String: Any],
              let ws = (version["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else {
            throw DevToolsError.badResponse
        }
        return ws
    }

    func browserPID() async throws -> pid_t {
        let result = try await withTimeout(8) { [self] in
            try await call("SystemInfo.getProcessInfo", on: try await browserWebSocketURL())
        }
        let processes = result["processInfo"] as? [[String: Any]] ?? []
        guard let browser = processes.first(where: { $0["type"] as? String == "browser" }),
              let id = browser["id"] as? Int else { throw DevToolsError.badResponse }
        return pid_t(id)
    }

    func targets() async throws -> [DevToolsTarget] {
        guard let list = try await getJSON("/json/list") as? [[String: Any]] else { throw DevToolsError.badResponse }
        return list.compactMap(DevToolsTarget.init(json:))
    }

    func mainWindow() async throws -> DevToolsTarget {
        guard let target = DevToolsTarget.mainWindow(in: try await targets()) else { throw DevToolsError.noMainWindow }
        return target
    }

    /// 在页面里执行表达式并按值返回结果（会等待 Promise）。
    func evaluate(_ expression: String, in target: DevToolsTarget, timeout: TimeInterval = 10) async throws -> Any? {
        let result = try await withTimeout(timeout) { [self] in
            try await call("Runtime.evaluate",
                           params: ["expression": expression, "awaitPromise": true, "returnByValue": true],
                           on: target.webSocketDebuggerURL)
        }
        if let details = result["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw DevToolsError.evaluation(exception?["description"] as? String ?? details["text"] as? String ?? "exception")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// 建一个 WebSocket，发一条命令，等到同 id 的回复后关闭。
    private func call(_ method: String, params: [String: Any] = [:], on url: URL) async throws -> [String: Any] {
        let task = Self.session.webSocketTask(with: url)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await sendAndReceive(method, params: params, task: task)
        } onCancel: {
            // 超时或停止 Bot 时同时关闭 socket，避免任务组一直卡在 receive()。
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private func sendAndReceive(_ method: String, params: [String: Any], task: URLSessionWebSocketTask) async throws -> [String: Any] {
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let messageID = Int.random(in: 1...1_000_000)
        let request: [String: Any] = ["id": messageID, "method": method, "params": params]
        let payload = try JSONSerialization.data(withJSONObject: request)
        try await task.send(.string(String(decoding: payload, as: UTF8.self)))

        while true {
            let data: Data
            switch try await task.receive() {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["id"] as? Int == messageID else { continue }   // 忽略事件推送
            if let error = obj["error"] as? [String: Any] {
                throw DevToolsError.evaluation(error["message"] as? String ?? "unknown")
            }
            guard let result = obj["result"] as? [String: Any] else { throw DevToolsError.badResponse }
            return result
        }
    }

    private func getJSON(_ path: String) async throws -> Any {
        do {
            let (data, response) = try await Self.session.data(from: base.appendingPathComponent(path))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DevToolsError.badResponse }
            return try JSONSerialization.jsonObject(with: data)
        } catch let error as DevToolsError {
            throw error
        } catch {
            throw DevToolsError.http(error.localizedDescription)
        }
    }
}

func withTimeout<T>(_ seconds: TimeInterval, _ body: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DevToolsError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw DevToolsError.timeout }
        return first
    }
}
