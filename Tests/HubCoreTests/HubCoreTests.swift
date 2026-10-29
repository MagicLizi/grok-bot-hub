import Foundation
import Testing
@testable import HubCore

@Suite struct LaunchArgumentsTests {
    @Test func makesIsolatedArguments() {
        #expect(LaunchArguments.make(userDataDir: "/a b/c") == ["--user-data-dir=/a b/c", "--remote-debugging-port=0"])
        #expect(LaunchArguments.environment(userDataDir: "/a b/c") == ["SAND_USER_DATA_DIR": "/a b/c"])
    }

    @Test func parsesBothFlagForms() {
        #expect(LaunchArguments.userDataDir(in: ["--user-data-dir=/x/y"]) == "/x/y")
        #expect(LaunchArguments.userDataDir(in: ["--user-data-dir", "/x/y", "--foo"]) == "/x/y")
        #expect(LaunchArguments.userDataDir(in: ["--user-data-dir", "--foo"]) == nil)
        #expect(LaunchArguments.userDataDir(in: ["--user-data-dir="]) == nil)
        #expect(LaunchArguments.userDataDir(in: ["-psn_0_123"]) == nil)
    }

    @Test func detectsRemoteDebugging() {
        #expect(LaunchArguments.hasRemoteDebugging(in: ["--remote-debugging-port=0"]))
        #expect(LaunchArguments.hasRemoteDebugging(in: ["--remote-debugging-port", "9222"]))
        #expect(!LaunchArguments.hasRemoteDebugging(in: ["--remote-debugging-pipe"]))
    }

    @Test func parsesProcArgsBuffer() {
        var buf: [UInt8] = []
        withUnsafeBytes(of: Int32(3).littleEndian) { buf.append(contentsOf: $0) }
        buf += Array("/Applications/Grok Bot.app/Contents/MacOS/Grok Bot".utf8) + [0, 0, 0, 0]
        for arg in ["/Applications/Grok Bot.app/Contents/MacOS/Grok Bot", "--user-data-dir=/p/q", "--remote-debugging-port=0"] {
            buf += Array(arg.utf8) + [0]
        }
        buf += Array("PATH=/usr/bin:/bin".utf8) + [0]   // 环境变量不应被当成参数
        let args = LaunchArguments.parseProcArgs(buf)
        #expect(args?.count == 3)
        #expect(args.map { LaunchArguments.userDataDir(in: $0) } == "/p/q")
    }
}

@Suite struct ProfileMatcherTests {
    @Test func matchesExactAndRemappedPaths() {
        let dir = URL(fileURLWithPath: "/Users/example/Library/Application Support/GrokBotHub/Profiles/ab12cd34")
        #expect(ProfileMatcher.matches(processDir: dir.path, profileDir: dir, profileID: "ab12cd34", hubFolderName: "GrokBotHub"))
        #expect(ProfileMatcher.matches(processDir: "/Volumes/example/Library/Application Support/GrokBotHub/Profiles/ab12cd34/",
                                       profileDir: dir, profileID: "ab12cd34", hubFolderName: "GrokBotHub"))
        #expect(!ProfileMatcher.matches(processDir: "/tmp/GrokBotHub/Profiles/ab12cd35", profileDir: dir, profileID: "ab12cd34", hubFolderName: "GrokBotHub"))
        #expect(!ProfileMatcher.matches(processDir: "/tmp/Other/Profiles/ab12cd34", profileDir: dir, profileID: "ab12cd34", hubFolderName: "GrokBotHub"))
    }
}

@Suite struct DevToolsTests {
    @Test func parsesActivePortFile() {
        let p = DevToolsActivePort(contents: "51472\n/devtools/browser/a888")
        #expect(p?.port == 51472)
        #expect(p?.browserPath == "/devtools/browser/a888")
        #expect(DevToolsActivePort(contents: "") == nil)
        #expect(DevToolsActivePort(contents: "abc\n") == nil)
        #expect(DevToolsActivePort(contents: "70000\n") == nil)
    }

    @Test func picksGrokBotMainWindow() {
        let list: [[String: Any]] = [
            ["id": "1", "type": "service_worker", "url": "https://x", "webSocketDebuggerUrl": "ws://127.0.0.1:1/devtools/page/1"],
            ["id": "2", "type": "page", "title": "Grok Bot",
             "url": "file:///Applications/Grok%20Bot.app/Contents/Resources/app.asar/dist/renderer/index.html",
             "webSocketDebuggerUrl": "ws://127.0.0.1:1/devtools/page/2"],
        ]
        let targets = list.compactMap(DevToolsTarget.init(json:))
        #expect(DevToolsTarget.mainWindow(in: targets)?.id == "2")
    }
}

@Suite struct AuthTests {
    @Test func decodesStatuses() {
        let a = GrokBotAuthStatus(json: ["kind": "logged-in", "email": "a@b.c", "displayName": "A"])
        #expect(a == GrokBotAuthStatus(kind: .loggedIn, email: "a@b.c", displayName: "A"))
        #expect(GrokBotAuthStatus(json: ["kind": "logged-out", "freshness": 1])?.kind == .loggedOut)
        #expect(GrokBotAuthStatus(json: ["kind": "logging-in"])?.kind == .loggingIn)
        #expect(GrokBotAuthStatus(json: ["foo": 1]) == nil)
        #expect(GrokBotLoginFlight(json: ["kind": "waiting-for-browser", "flow": "sign-in"]) == .waitingForBrowser)
        #expect(GrokBotLoginFlight(json: ["kind": "idle"]) == .idle)
    }

    @Test func validatesLoginLinks() {
        let good = "https://cursor.com/loginDeepControl?challenge=abc&uuid=1-2&mode=login&redirectTarget=sand"
        #expect(LoginLink.validate(good) != nil)
        #expect(LoginLink.validate("  \(good)\n") != nil)
        #expect(LoginLink.validate("http://cursor.com/loginDeepControl?challenge=a&uuid=b") == nil)
        #expect(LoginLink.validate("https://evil.com/loginDeepControl?challenge=a&uuid=b") == nil)
        #expect(LoginLink.validate("https://cursor.com.evil.com/loginDeepControl?challenge=a&uuid=b") == nil)
        #expect(LoginLink.validate("https://cursor.com/loginDeepControl?uuid=b") == nil)
        #expect(LoginLink.validate("hello") == nil)
    }

    @Test func blocksAppCallbackSchemes() {
        #expect(LoginLink.isAppCallbackScheme("grokbot"))
        #expect(LoginLink.isAppCallbackScheme("SAND"))
        #expect(!LoginLink.isAppCallbackScheme("https"))
        #expect(!LoginLink.isAppCallbackScheme(nil))
    }
}

@Suite struct PolicyTests {
    @Test func backoffGrowsAndCaps() {
        let p = RestartPolicy()
        #expect(p.delay(forConsecutiveRestarts: 0) == 2)
        #expect(p.delay(forConsecutiveRestarts: 3) == 30)
        #expect(p.delay(forConsecutiveRestarts: 99) == 300)
        #expect(p.delay(forConsecutiveRestarts: -1) == 2)
        let now = Date()
        #expect(p.isStable(runningSince: now.addingTimeInterval(-601), now: now))
        #expect(!p.isStable(runningSince: now.addingTimeInterval(-30), now: now))
    }

    @Test func hangNeedsRepeatedFailuresAfterGrace() {
        let h = HangPolicy(failuresBeforeRestart: 4, startupGrace: 90)
        let now = Date()
        #expect(!h.shouldRestart(consecutiveFailures: 3, runningSince: now.addingTimeInterval(-600), now: now))
        #expect(h.shouldRestart(consecutiveFailures: 4, runningSince: now.addingTimeInterval(-600), now: now))
        #expect(!h.shouldRestart(consecutiveFailures: 10, runningSince: now.addingTimeInterval(-30), now: now))
    }
}
