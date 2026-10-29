import Foundation

/// Grok Bot（Electron）实例的启动参数约定。
///
/// - `SAND_USER_DATA_DIR`：Grok Bot 0.78.1 使用的隔离目录；保留旧参数以兼容旧版及进程识别。
/// - `--remote-debugging-port=0`：Chromium 随机选一个仅监听 127.0.0.1 的端口，并写入
///   `<user-data-dir>/DevToolsActivePort`，宿主据此接管登录与健康检查。
public enum LaunchArguments {
    public static let userDataDirFlag = "--user-data-dir"
    public static let remoteDebuggingFlag = "--remote-debugging-port"

    public static func make(userDataDir: String) -> [String] {
        ["\(userDataDirFlag)=\(userDataDir)", "\(remoteDebuggingFlag)=0"]
    }

    /// 新版本会覆盖 Chromium 的 --user-data-dir，必须同时使用应用自己的环境变量。
    /// 显式指定业务数据目录，避免继承的 SAND_DATA_ROOT 把多个账号导向同一目录。
    public static func environment(userDataDir: String) -> [String: String] {
        ["SAND_USER_DATA_DIR": userDataDir,
         "SAND_DATA_ROOT": URL(fileURLWithPath: userDataDir).appendingPathComponent("sand-data").path]
    }

    /// 支持 `--flag=value` 与 `--flag value` 两种写法（与 Grok Bot 自身的解析一致）。
    public static func value(of flag: String, in args: [String]) -> String? {
        for (i, arg) in args.enumerated() {
            if arg == flag {
                let next = i + 1 < args.count ? args[i + 1] : nil
                return next.flatMap { $0.hasPrefix("--") ? nil : $0 }
            }
            if arg.hasPrefix(flag + "=") {
                return String(arg.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    public static func userDataDir(in args: [String]) -> String? {
        value(of: userDataDirFlag, in: args)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    public static func hasRemoteDebugging(in args: [String]) -> Bool {
        args.contains { $0 == remoteDebuggingFlag || $0.hasPrefix(remoteDebuggingFlag + "=") }
    }

    /// 解析 sysctl(KERN_PROCARGS2) 返回的原始缓冲区：argc(Int32) | exec_path | \0... | argv[0..argc)。
    public static func parseProcArgs(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count > 4 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return [] }
        var i = 4
        while i < buffer.count, buffer[i] != 0 { i += 1 }   // exec path
        while i < buffer.count, buffer[i] == 0 { i += 1 }   // 对齐填充
        var args: [String] = []
        while args.count < argc, i < buffer.count {
            let start = i
            while i < buffer.count, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}

/// 判断某个进程的 `--user-data-dir` 是否属于指定 profile。
///
/// 先比较规范化后的完整路径；再兜底比较 `<hubFolder>/Profiles/<id>` 结尾，
/// 以兼容路径经过符号链接或家目录重映射的情况。
public enum ProfileMatcher {
    public static func matches(processDir: String, profileDir: URL, profileID: String, hubFolderName: String) -> Bool {
        let a = URL(fileURLWithPath: processDir).standardizedFileURL.resolvingSymlinksInPath().path
        let b = profileDir.standardizedFileURL.resolvingSymlinksInPath().path
        if a == b { return true }
        let suffix = "/\(hubFolderName)/Profiles/\(profileID)"
        return trimTrailingSlash(a).hasSuffix(suffix)
    }

    private static func trimTrailingSlash(_ s: String) -> String {
        s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
