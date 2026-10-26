import AppKit
import IOKit.pwr_mgt
import UserNotifications

/// 这台 Mac 当前是否锁屏。锁屏时 Grok Bot 认为没人在电脑前，不会唤醒云端电脑。
func isMacScreenLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
}

/// 有 Bot 在运行时阻止闲置休眠。
@MainActor
final class SleepGuard {
    enum Mode {
        /// 只阻止系统休眠，显示器照常关闭
        case system
        /// 显示器也不因闲置关闭（同时阻止系统休眠）。锁屏由显示器关闭或屏保触发，显示器常亮就不会自动锁屏
        case display
    }

    private var assertionID = IOPMAssertionID(0)
    private(set) var mode: Mode?

    var isHolding: Bool { mode != nil }

    func update(_ wanted: Mode?) {
        guard wanted != mode else { return }
        if mode != nil {
            IOPMAssertionRelease(assertionID)
            mode = nil
            if wanted == nil { HubLog.write("已恢复系统休眠") }
        }
        guard let wanted else { return }
        let type = wanted == .display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Grok Bot Hub：保持 Grok Bot 在线" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else { return }
        mode = wanted
        HubLog.write(wanted == .display ? "已保持显示器常亮（防止 Mac 锁屏）" : "已阻止系统闲置休眠")
    }
}

enum Notifier {
    /// 只在作为 .app 运行时可用；`swift run` 直接跑可执行文件时没有 bundle，调用会崩溃。
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        HubLog.write("通知：\(title) — \(body)")
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}

/// Grok Bot 会把登录链接写进剪贴板；取完链接后把用户原来的剪贴板内容放回去。
@MainActor
enum PasteboardCapture {
    static func captureString(_ action: () async throws -> Void) async throws -> String? {
        let pasteboard = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let before = pasteboard.changeCount
        try await action()

        var captured: String?
        for _ in 0..<30 where captured == nil {
            if pasteboard.changeCount != before {
                captured = pasteboard.string(forType: .string)
            } else {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        if pasteboard.changeCount != before {
            pasteboard.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        return captured
    }
}
