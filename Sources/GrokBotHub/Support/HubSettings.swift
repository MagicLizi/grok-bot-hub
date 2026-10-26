import Foundation

/// 用户偏好，存在 UserDefaults；视图里用 @AppStorage 读写同一组 key。
enum SettingKey {
    static let preventSleep = "preventSleep"
    static let keepDisplayAwake = "keepDisplayAwake"
    static let keepComputersAwake = "keepComputersAwake"
    static let disableGrokBotAppNap = "disableGrokBotAppNap"
    static let restartUnresponsive = "restartUnresponsive"
    static let grokBotAppPath = "grokBotAppPath"
    static let loginMode = "loginMode"
}

/// 登录页在哪里打开。
enum LoginMode: String, CaseIterable {
    /// 全新的临时会话：不带任何已有登录状态，适合给每个 Bot 登不同账号
    case isolated
    /// 默认浏览器：和 Grok Bot 自带的登录完全一样，沿用浏览器里已有的登录状态（公司单点登录账号用这个）
    case browser
}

enum HubSettings {
    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingKey.preventSleep: true,
            SettingKey.keepDisplayAwake: true,
            SettingKey.keepComputersAwake: true,
            SettingKey.disableGrokBotAppNap: true,
            SettingKey.restartUnresponsive: true,
            SettingKey.loginMode: LoginMode.isolated.rawValue,
        ])
    }

    static var preventSleep: Bool { UserDefaults.standard.bool(forKey: SettingKey.preventSleep) }
    static var keepDisplayAwake: Bool { UserDefaults.standard.bool(forKey: SettingKey.keepDisplayAwake) }
    static var keepComputersAwake: Bool { UserDefaults.standard.bool(forKey: SettingKey.keepComputersAwake) }
    static var disableGrokBotAppNap: Bool { UserDefaults.standard.bool(forKey: SettingKey.disableGrokBotAppNap) }
    static var restartUnresponsive: Bool { UserDefaults.standard.bool(forKey: SettingKey.restartUnresponsive) }
    static var grokBotAppPath: String? {
        UserDefaults.standard.string(forKey: SettingKey.grokBotAppPath).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var loginMode: LoginMode {
        get { UserDefaults.standard.string(forKey: SettingKey.loginMode).flatMap(LoginMode.init(rawValue:)) ?? .isolated }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingKey.loginMode) }
    }
}
