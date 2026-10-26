import Foundation

enum HubPaths {
    static let folderName = "GrokBotHub"

    static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(folderName, isDirectory: true)

    static var profilesDir: URL { root.appendingPathComponent("Profiles", isDirectory: true) }
    static var profilesFile: URL { root.appendingPathComponent("profiles.json") }

    static let logsDir: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/\(folderName)", isDirectory: true)

    static var logFile: URL { logsDir.appendingPathComponent("hub.log") }

    /// 每个 Bot 一个独立数据目录，作为 Grok Bot 的 `--user-data-dir`。
    static func dataDir(for id: String) -> URL {
        profilesDir.appendingPathComponent(id, isDirectory: true)
    }

    static func ensureDirectories() {
        for dir in [root, profilesDir, logsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
