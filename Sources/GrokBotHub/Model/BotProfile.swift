import Foundation

/// 一个受管的 Grok Bot 实例（持久化部分）。
struct BotProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let createdAt: Date
    /// 保活开关：开启时宿主保证它一直在运行，退出/崩溃/卡死都会被拉起。
    var keepAlive: Bool
    /// 宿主内登录窗口使用的 WKWebsiteDataStore 标识，每个 Bot 的 cursor.com 网页会话互相隔离。
    var webStoreID: UUID
    var accountEmail: String?
    var accountName: String?
    var lastLoginAt: Date?

    var dataDir: URL { HubPaths.dataDir(for: id) }

    static func make(name: String) -> BotProfile {
        BotProfile(
            id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased(),
            name: name,
            createdAt: Date(),
            keepAlive: true,
            webStoreID: UUID()
        )
    }
}

/// profiles.json 读写。
enum ProfileStore {
    static func load() -> [BotProfile] {
        guard let data = try? Data(contentsOf: HubPaths.profilesFile) else { return [] }
        do {
            return try decoder.decode([BotProfile].self, from: data)
        } catch {
            // 文件损坏时保留原件，避免下一次保存把它覆盖掉
            let backup = HubPaths.profilesFile.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: HubPaths.profilesFile, to: backup)
            HubLog.write("profiles.json 解析失败，已备份到 \(backup.lastPathComponent)：\(error)")
            return []
        }
    }

    static func save(_ profiles: [BotProfile]) {
        do {
            let data = try encoder.encode(profiles)
            try data.write(to: HubPaths.profilesFile, options: .atomic)
        } catch {
            HubLog.write("保存 profiles.json 失败：\(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
